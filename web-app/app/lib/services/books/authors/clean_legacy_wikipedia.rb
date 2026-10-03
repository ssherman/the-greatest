# frozen_string_literal: true

module Services
  module Books
    module Authors
      # Legacy descriptions sourced from Wikipedia came from a text search and
      # are often the wrong page (17% name a page without the author's
      # surname; a sample of 12 had six wrong). Spec §13: keep one only when
      # its page is the matched item's article; deprecate the rest, including
      # every one of an author who could not be matched. Deprecated, not
      # deleted, so it can be undone, and one deprecated only because no one
      # matched is restored when a later run (the forced one after VIAF found
      # the item, say) matches its page. Exercised by the backfill: imports
      # create no legacy descriptions.
      class CleanLegacyWikipedia
        TITLE_PATH = %r{\A/wiki/(.+)\z}
        HOST = /\A([a-z][a-z-]*)\.(?:m\.)?wikipedia\.org\z/

        def self.call(author:, entity:, refresh: false, client: nil)
          new(author: author, entity: entity, refresh: refresh, client: client).call
        end

        def initialize(author:, entity:, refresh:, client:)
          @author = author
          @entity = entity
          @refresh = refresh
          @client = client
        end

        def call
          active = @author.descriptions.select { |description| description.source == "wikipedia" && !description.deprecated? }
          revisit = @entity ? unmatched_deprecations : []
          return nil if active.empty? && revisit.empty?

          # Two phases: every verdict is decided (including any WikipediaLead
          # fetches) before any row changes, so a raise partway through (a
          # rate limit) leaves no untraced change.
          judged = active.map { |description| [description, verdict_for(description)] } +
            revisit.map { |description| [description, rejudged(verdict_for(description))] }
          judged.each do |description, verdict|
            case verdict["verdict"]
            when "deprecated" then description.update!(rank: :deprecated)
            when "restored" then description.update!(rank: :normal)
            end
          end

          verdicts = judged.map(&:last)
          # Array#& keeps the receiver's order, so "deprecated" wins the reason over "restored".
          changes = %w[deprecated restored] & verdicts.map { |verdict| verdict["verdict"] }
          {"value" => verdicts, "applied" => changes.any?, "reason" => changes.first || "kept"}
        end

        private

        def verdict_for(description)
          return entry(description, "deprecated", "author_unmatched") if @entity.nil?

          language, title = parse(description.source_url)
          return entry(description, "deprecated", "unreadable_url") if title.nil?
          return entry(description, "kept", "sitelink") if language == "en" && title == @entity.enwiki_title

          lead = fetch_lead(language, title)
          return entry(description, "deprecated", "unreadable_url") if lead == :unreadable
          return entry(description, "deprecated", "page_missing") if lead.nil?
          return entry(description, "kept", "same_item") if lead.wikibase_item == @entity.id

          entry(description, "deprecated", "different_item", page_item: lead.wikibase_item)
        end

        # A description deprecated only because an earlier run matched no one
        # (author_unmatched) is judged again once a run matches: kept now
        # means it is the matched item's article after all.
        def rejudged(verdict)
          verdict.merge("verdict" => (verdict["verdict"] == "kept") ? "restored" : "left_deprecated")
        end

        # This author's Wikipedia descriptions that a Wikidata run of this
        # era (newer than the author row, spec §14) deprecated as
        # author_unmatched, and that are deprecated still.
        def unmatched_deprecations
          ids = @author.enrichments.for_kind(EnrichFromWikidata::KIND).where("enrichments.created_at > ?", @author.created_at)
            .flat_map { |row| Array(row.facts.dig("legacy_wikipedia", "value")) }
            .select { |verdict| verdict["verdict"] == "deprecated" && verdict["why"] == "author_unmatched" }
            .map { |verdict| verdict["description_id"] }.to_set
          @author.descriptions.select { |description| description.source == "wikipedia" && description.deprecated? && ids.include?(description.id) }
        end

        # A language the Wikipedia client's own guard rejects (a "simple." or
        # "www." host is not a real Wikipedia language edition) is unreadable,
        # not a failure.
        def fetch_lead(language, title)
          WikipediaLead.fetch(language: language, title: title, refresh: @refresh, client: @client)
        rescue ArgumentError
          :unreadable
        end

        def entry(description, verdict, why, **extra)
          {"description_id" => description.id, "url" => description.source_url, "verdict" => verdict, "why" => why}
            .merge(extra.stringify_keys)
        end

        # [language, title] from https://en.wikipedia.org/wiki/Leo_Tolstoy or
        # its mobile form; [nil, nil] for anything else.
        def parse(url)
          uri = URI.parse(url.to_s)
          language = uri.host.to_s[HOST, 1]
          path = uri.path.to_s[TITLE_PATH, 1]
          return [nil, nil] if language.nil? || path.nil?

          [language, URI.decode_uri_component(path).tr("_", " ")]
        rescue URI::InvalidURIError, ArgumentError
          [nil, nil]
        end
      end
    end
  end
end
