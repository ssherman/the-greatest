# frozen_string_literal: true

module Wikidata
  # The Wikidata operations the author steps use (spec §4), answered by the
  # local read-only Wikidata service (docs/features/wikidata-data-service.md),
  # never by wikidata.org. The service is the only source: there is no live
  # fallback. When it cannot answer, Exceptions::Unavailable (a RateLimited)
  # is raised and the job retries later.
  class Client
    MAX_IDS = 50
    MAX_LABEL_IDS = 500
    MAX_TARGETS = 100
    SEARCH_LIMIT = 10
    STATEMENT_LIMIT = 10
    MAX_STATEMENT_VALUE = 200 # the service's per-value limit (ExternalIdRequest)
    MAX_STATEMENT_PAIRS = 500 # and its pair limit
    WORKS_ROW_LIMIT = 5000
    WORK_PROPERTIES = %w[P50 P800].freeze
    # Editions repeat their work's titles. Scholarly articles are not in the service's kept set at all.
    EXCLUDED_WORK_TYPES = %w[Q3331189].freeze
    ITEM_ID = /\AQ[1-9]\d*\z/
    PROPERTY_ID = /\AP[1-9]\d*\z/
    ISO_CODE = /\A[A-Z]{2}\z/
    COUNTRY_CODE_PROPERTY = "P297"

    # The asked QIDs the most recent #entities call reported as outside the
    # service's kept set: they exist in Wikidata, so a caller must not treat
    # them as gone and drop a stored identifier. #dump_date is the dump the
    # most recent answer that carried one came from.
    attr_reader :not_kept, :dump_date

    def initialize(service: nil)
      @service = service || Service.new
      @not_kept = Set.new
      @dump_date = nil
    end

    # Keyed by the id asked for: a merged item answers under the surviving
    # item's id inside the entity, so a caller can tell a redirect happened.
    # Missing and not-kept ids are absent; the latter are in #not_kept.
    def entities(ids)
      @not_kept = Set.new
      found = {}
      valid_ids(ids).each_slice(MAX_IDS) do |slice|
        data = @service.post("/items", {ids: slice})
        items = data["items"] || {}
        found.merge!(items)
        @not_kept.merge(Array(data["not_kept"]))
        remember_dump_date(items.values)
      end
      found
    end

    def search(name)
      return [] if name.to_s.strip.empty?

      data = @service.get("/names", {q: name.to_s, limit: SEARCH_LIMIT})
      Array(data["hits"]).map { |hit| {"id" => hit["id"], "label" => hit["label"], "description" => hit["description"]} }
    end

    # The items carrying any of the property=value pairs.
    def by_statements(pairs, limit: STATEMENT_LIMIT)
      safe = Array(pairs).select { |property, value| property.to_s.match?(PROPERTY_ID) && value.to_s.present? && value.to_s.length <= MAX_STATEMENT_VALUE }
        .first(MAX_STATEMENT_PAIRS)
      return [] if safe.empty?

      data = @service.post("/by-external-id", {pairs: safe.map { |property, value| [property.to_s, value.to_s] }, limit: limit})
      Array(data["ids"]).grep(ITEM_ID)
    end

    # Every title (English, else the all-languages "mul" label) of the works each item wrote (P50, read backwards)
    # or is known for (P800). Scholarly articles and editions are left out: a
    # scientist can author thousands of articles, and editions repeat titles.
    def works(item_ids)
      each_work_row(item_ids).each_with_object({}) do |(author, _work, label), found|
        titles = (found[author] ||= [])
        titles << label unless titles.include?(label)
      end
    end

    # The works of each item as id and label pairs, keyed by author id.
    def work_items(item_ids)
      each_work_row(item_ids).each_with_object({}) do |(author, work, label), found|
        next if work.nil?

        items = (found[author] ||= [])
        items << {"id" => work, "label" => label} unless items.any? { |item| item["id"] == work }
      end
    end

    # {qid => {"code", "label"}}: the best-rank P297 (preferred if any, else
    # normal, never deprecated), and the English label, else the
    # all-languages one. Countries the service does not hold are absent.
    def country_codes(item_ids)
      found = {}
      valid_ids(item_ids).each_slice(MAX_IDS) do |slice|
        items = @service.post("/items", {ids: slice})["items"] || {}
        remember_dump_date(items.values)
        items.each { |asked, entity| found[asked] = {"code" => country_code(entity), "label" => label_of(entity)} }
      end
      found
    end

    def labels(item_ids)
      found = {}
      valid_ids(item_ids).each_slice(MAX_LABEL_IDS) do |slice|
        (@service.post("/labels", {ids: slice})["labels"] || {}).each do |qid, entry|
          label = entry["en"].presence || entry["mul"].presence
          found[qid] = label if label
        end
      end
      found
    end

    private

    def valid_ids(ids) = Array(ids).map(&:to_s).uniq.grep(ITEM_ID)

    def remember_dump_date(entities)
      date = entities.filter_map { |entity| entity["dump_date"] if entity.is_a?(Hash) }.last
      @dump_date = date if date
    end

    def label_of(entity)
      labels = entity["labels"].is_a?(Hash) ? entity["labels"] : {}
      labels.dig("en", "value").presence || labels.dig("mul", "value").presence
    end

    def country_code(entity)
      statements = Array(entity.dig("claims", COUNTRY_CODE_PROPERTY)).select { |statement| statement.is_a?(Hash) && statement["rank"] != "deprecated" }
      preferred = statements.select { |statement| statement["rank"] == "preferred" }
      (preferred.presence || statements).each do |statement|
        value = statement.dig("mainsnak", "datavalue", "value").to_s
        return value if value.match?(ISO_CODE)
      end
      nil
    end

    # The one P50/P800 query behind #works and #work_items: [author, work, label]
    # per row.
    def each_work_row(item_ids)
      valid_ids(item_ids).each_slice(MAX_TARGETS).flat_map do |slice|
        data = @service.post("/linked-from", {targets: slice, properties: WORK_PROPERTIES,
          exclude_types: EXCLUDED_WORK_TYPES, limit: WORKS_ROW_LIMIT})
        if data["truncated"]
          Rails.logger.warn("Wikidata::Client works query: the answer hit the #{WORKS_ROW_LIMIT}-row limit for " \
            "#{slice.join(", ")}; works past it were cut")
        end
        Array(data["rows"]).filter_map do |author, work, label|
          [author, work, label] if author.present? && label.present?
        end
      end
    end
  end
end
