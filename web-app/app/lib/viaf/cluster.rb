# frozen_string_literal: true

module Viaf
  # Fetches one cluster by VIAF ID, and owns the cache.
  #
  # Person is always built from the distilled payload, never from raw response
  # JSON, so a cache hit and a fresh fetch cannot diverge.
  class Cluster
    def initialize(client = nil)
      @client = client || BaseClient.new
    end

    def find(viaf_id, refresh: false)
      id = viaf_id.to_s
      raise ArgumentError, "viaf_id cannot be blank" if id.blank?

      record = ExternalRecord.find_by(source: :viaf, source_id: id) unless refresh
      return Person.from_payload(record.payload) if record

      payload = fetch_and_distill(id)
      store(id, payload)
      Person.from_payload(payload)
    end

    private

    def fetch_and_distill(id)
      response = @client.get("viaf/#{id}")
      Distiller.call(response[:data], requested_id: id)
    end

    def store(id, payload)
      record = ExternalRecord.find_or_initialize_by(source: :viaf, source_id: id)
      record.payload = payload
      record.schema_version = Distiller::SCHEMA_VERSION
      record.fetched_at = Time.current
      record.save!
    end
  end
end
