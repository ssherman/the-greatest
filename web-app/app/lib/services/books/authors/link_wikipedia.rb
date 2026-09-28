# frozen_string_literal: true

module Services
  module Books
    module Authors
      # The matched item's English article (spec §5.4). Wikidata allows one
      # article per item per wiki, so the sitelink is by construction about
      # the item; the page must still name the same item back and must not be
      # a disambiguation page. Adds the link and keeps the lead in
      # external_records as evidence for the AI step. The text is never shown.
      class LinkWikipedia
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        LANGUAGE = "en"

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
          title = @entity.enwiki_title
          return done(nil, false, "no_sitelink") if title.blank?

          lead = WikipediaLead.fetch(language: LANGUAGE, title: title, refresh: @refresh, client: @client)
          return done(title, false, "missing") if lead.nil?
          return done(lead.url, false, "item_mismatch", page_item: lead.wikibase_item) if lead.wikibase_item != @entity.id
          return done(lead.url, false, "disambiguation") if lead.disambiguation?

          record = WikipediaLead.store(lead)
          link = @author.external_links.find_or_initialize_by(url: lead.url)
          created = link.new_record?
          if created
            link.assign_attributes(name: "Wikipedia", source: :wikipedia, link_category: :information)
            link.save!
          end
          done(lead.url, created, created ? "linked" : "already_set", lead: lead, record: record, page: lead.source_id)
        end

        private

        def done(value, applied, reason, lead: nil, record: nil, **extra)
          fact = {"value" => value, "applied" => applied, "reason" => reason}.merge(extra.deep_stringify_keys)
          Result.new(success?: true, data: {fact: fact, lead: lead, record: record}, errors: [])
        end
      end
    end
  end
end
