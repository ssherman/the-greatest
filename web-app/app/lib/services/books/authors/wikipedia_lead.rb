# frozen_string_literal: true

module Services
  module Books
    module Authors
      # Read-through for Wikipedia leads (spec §3). A stored lead is keyed by
      # page id, which is unknown before a fetch, so it is found by language
      # and title instead.
      class WikipediaLead
        def self.fetch(language:, title:, refresh: false, client: nil)
          unless refresh
            stored = ::ExternalRecord.where(source: :wikipedia, schema_version: ::Wikipedia::Lead::SCHEMA_VERSION)
              .where("payload->>'language' = ? AND payload->>'title' = ?", language, title).first
            return ::Wikipedia::Lead.from_payload(stored.payload) if stored
          end

          (client || ::Wikipedia::Client.new).lead(language: language, title: title)
        end

        # A lead read from storage has no raw body and is already held.
        def self.store(lead)
          return ::ExternalRecord.find_by(source: :wikipedia, source_id: lead.source_id) if lead.raw.nil?

          ::Services::ExternalRecords::Store.write(source: :wikipedia, source_id: lead.source_id, payload: lead.to_payload,
            raw: lead.raw, schema_version: ::Wikipedia::Lead::SCHEMA_VERSION)
        end
      end
    end
  end
end
