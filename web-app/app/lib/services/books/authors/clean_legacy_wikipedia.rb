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

          verdicts = rows.map { |description| verdict_for(description) }
          deprecated = verdicts.any? { |verdict| verdict["verdict"] == "deprecated" }
          {"value" => verdicts, "applied" => deprecated, "reason" => deprecated ? "deprecated" : "kept"}
        end

        private

        def verdict_for(description)
          return deprecate(description, "author_unmatched") if @entity.nil?

          language, title = parse(description.source_url)
          return deprecate(description, "unreadable_url") if title.nil?
          return keep(description, "sitelink") if language == "en" && title == @entity.enwiki_title

          lead = WikipediaLead.fetch(language: language, title: title, refresh: @refresh, client: @client)
          return deprecate(description, "page_missing") if lead.nil?
          return keep(description, "same_item") if lead.wikibase_item == @entity.id

          deprecate(description, "different_item", page_item: lead.wikibase_item)
        end

        def keep(description, why, **extra) = entry(description, "kept", why, extra)

        def deprecate(description, why, **extra)
          description.update!(rank: :deprecated)
          entry(description, "deprecated", why, extra)
        end

        def entry(description, verdict, why, extra)
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
