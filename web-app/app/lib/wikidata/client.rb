# frozen_string_literal: true

module Wikidata
  # The Wikidata operations the author steps use (spec §4), over the paced
  # Wikimedia::Http. Country and label lookups are cached for 30 days in
  # config.x.external_api_cache: they repeat across nearly every author, and
  # a country entity fetched whole can be megabytes.
  class Client
    API_URL = "https://www.wikidata.org/w/api.php"
    SPARQL_URL = "https://query.wikidata.org/sparql"
    MAX_IDS = 50
    SEARCH_LIMIT = 10
    STATEMENT_LIMIT = 10
    WORKS_ROW_LIMIT = 5000
    CACHE_TTL = 30.days
    ITEM_ID = /\AQ\d+\z/
    ISO_CODE = /\A[A-Z]{2}\z/
    # A value is safe inside haswbstatement when it has no space or quote.
    STATEMENT_VALUE = /\A[\w.-]+\z/

    def initialize(http: nil, cache: nil)
      @http = http || ::Wikimedia::Http.new
      @cache = cache || Rails.application.config.x.external_api_cache
    end

    # Keyed by the id asked for: a merged item answers under the surviving
    # item's id inside the entity, so a caller can tell a redirect happened.
    def entities(ids)
      ids = Array(ids).map(&:to_s).uniq.grep(ITEM_ID)
      ids.each_slice(MAX_IDS).each_with_object({}) do |slice, found|
        data = @http.action_api(API_URL, action: "wbgetentities", ids: slice.join("|")).data
        (data["entities"] || {}).each do |requested, entity|
          found[requested] = entity if entity.is_a?(Hash) && !entity.key?("missing")
        end
      end
    end

    def search(name)
      return [] if name.to_s.strip.empty?

      data = @http.action_api(API_URL, action: "wbsearchentities", search: name.to_s, language: "en", uselang: "en",
        type: "item", limit: SEARCH_LIMIT).data
      Array(data["search"]).map { |hit| {"id" => hit["id"], "label" => hit["label"], "description" => hit["description"]} }
    end

    # One CirrusSearch query: `haswbstatement:P648=OL1A|P214=123` matches an
    # item carrying any of the pairs.
    def by_statements(pairs)
      safe = Array(pairs).select { |property, value| property.to_s.match?(/\AP\d+\z/) && value.to_s.match?(STATEMENT_VALUE) }
      return [] if safe.empty?

      expression = safe.map { |property, value| "#{property}=#{value}" }.join("|")
      data = @http.action_api(API_URL, action: "query", list: "search", srsearch: "haswbstatement:#{expression}",
        srnamespace: 0, srlimit: STATEMENT_LIMIT, srprop: "").data
      Array(data.dig("query", "search")).map { |hit| hit["title"] }.grep(ITEM_ID)
    end

    # Every English title of the works each item wrote (P50, read backwards)
    # or is known for (P800). Scholarly articles and editions are left out: a
    # scientist can author thousands of articles, and editions repeat titles.
    def works(item_ids)
      ids = Array(item_ids).map(&:to_s).uniq.grep(ITEM_ID)
      return {} if ids.empty?

      query = <<~SPARQL
        SELECT ?author ?workLabel WHERE {
          VALUES ?author { #{ids.map { |id| "wd:#{id}" }.join(" ")} }
          { ?work wdt:P50 ?author } UNION { ?author wdt:P800 ?work }
          FILTER NOT EXISTS { ?work wdt:P31 wd:Q13442814 }
          FILTER NOT EXISTS { ?work wdt:P31 wd:Q3331189 }
          ?work rdfs:label ?workLabel . FILTER(LANG(?workLabel) = "en")
        } LIMIT #{WORKS_ROW_LIMIT}
      SPARQL
      rows = bindings(@http.sparql(SPARQL_URL, query))
      if rows.size >= WORKS_ROW_LIMIT
        Rails.logger.warn("Wikidata::Client#works: #{rows.size} rows filled the #{WORKS_ROW_LIMIT}-row limit for " \
          "#{ids.join(", ")}; titles past it were cut")
      end
      rows.each_with_object({}) do |row, found|
        id = entity_id(row["author"])
        title = row.dig("workLabel", "value")
        next if id.nil? || title.blank?

        titles = (found[id] ||= [])
        titles << title unless titles.include?(title)
      end
    end

    def country_codes(item_ids)
      ids = Array(item_ids).map(&:to_s).uniq.grep(ITEM_ID)
      cached = read_cached("country", ids)
      missing = ids - cached.keys
      return cached if missing.empty?

      query = <<~SPARQL
        SELECT ?country ?code ?countryLabel WHERE {
          VALUES ?country { #{missing.map { |id| "wd:#{id}" }.join(" ")} }
          OPTIONAL { ?country wdt:P297 ?code }
          SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
        }
      SPARQL
      fetched = {}
      bindings(@http.sparql(SPARQL_URL, query)).each do |row|
        id = entity_id(row["country"])
        next if id.nil?

        entry = (fetched[id] ||= {"code" => nil, "label" => row.dig("countryLabel", "value")})
        code = row.dig("code", "value").to_s
        entry["code"] ||= code if code.match?(ISO_CODE)
      end
      fetched.each { |id, entry| @cache.write(cache_key("country", id), entry, expires_in: CACHE_TTL) }
      cached.merge(fetched)
    end

    def labels(item_ids)
      ids = Array(item_ids).map(&:to_s).uniq.grep(ITEM_ID)
      cached = read_cached("label", ids)
      fetched = {}
      (ids - cached.keys).each_slice(MAX_IDS) do |slice|
        data = @http.action_api(API_URL, action: "wbgetentities", ids: slice.join("|"), props: "labels", languages: "en").data
        (data["entities"] || {}).each do |requested, entity|
          label = (entity.is_a?(Hash) && entity["labels"].is_a?(Hash)) ? entity["labels"].dig("en", "value") : nil
          next if label.blank?

          fetched[requested] = label
          @cache.write(cache_key("label", requested), label, expires_in: CACHE_TTL)
        end
      end
      cached.merge(fetched)
    end

    private

    def bindings(response) = Array(response.data.dig("results", "bindings"))

    def entity_id(binding) = binding.is_a?(Hash) ? binding["value"].to_s[%r{/entity/(Q\d+)\z}, 1] : nil

    def cache_key(kind, id) = "wikidata:#{kind}:#{id}"

    def read_cached(kind, ids)
      return {} if ids.empty?

      keys = ids.index_by { |id| cache_key(kind, id) }
      @cache.read_multi(*keys.keys).transform_keys { |key| keys[key] }
    end
  end
end
