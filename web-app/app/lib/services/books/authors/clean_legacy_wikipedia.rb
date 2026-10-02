# frozen_string_literal: true

module Services
  module Books
    module Authors
      # Legacy descriptions sourced from Wikipedia came from a text search and
      # are often the wrong page (17% name a page without the author's
      # surname; a sample of 12 had six wrong). Spec §13: keep one only when
      # its page is the matched item's article; deprecate the rest, including
      # every one of an author who could not be matched. Deprecated, not
      # deleted, so it can be undone. Exercised by the backfill: imports
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
          rows = @author.descriptions.select { |description| description.source == "wikipedia" && !description.deprecated? }
          return nil if rows.empty?

          # Two phases: every verdict is decided (including any WikipediaLead
          # fetches) before any row is deprecated, so a raise partway through
          # (a rate limit) leaves no untraced deprecation.
          judged = rows.map { |description| [description, verdict_for(description)] }
          judged.each { |description, verdict| description.update!(rank: :deprecated) if verdict["verdict"] == "deprecated" }

          verdicts = judged.map { |_description, verdict| verdict }
          deprecated = verdicts.any? { |verdict| verdict["verdict"] == "deprecated" }
          {"value" => verdicts, "applied" => deprecated, "reason" => deprecated ? "deprecated" : "kept"}
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
