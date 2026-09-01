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
      return Person.from_payload(record.payload) if record && current_schema?(record)

      payload = fetch_and_distill(id)
      store(id, payload)
      Person.from_payload(payload)
    end

    private

    # A row written by an older distiller is a cache miss, not a hit: the
    # payload may be missing fields the current SCHEMA_VERSION distills.
    def current_schema?(record)
      record.schema_version == Distiller::SCHEMA_VERSION
    end

    def fetch_and_distill(id)
      response = @client.get("viaf/#{id}")
      Distiller.call(response[:data], requested_id: id)
    end

    # `find` already checked the cache under this row's key, but that check
    # and this write are not atomic: RateLimiter is blocking (2 req/min), so
    # the window between another worker's SELECT and its committed INSERT can
    # be tens of seconds wide. If we lose that race, the unique index on
    # (source, source_id) rejects our insert (RecordNotUnique) or the
    # uniqueness validation catches it first (RecordInvalid). Either way the
    # winner already persisted a payload distilled from the same cluster, so
    # losing is not an error -- `find` still returns a correct Person built
    # from its own freshly-distilled payload.
    def store(id, payload)
      record = ExternalRecord.find_or_initialize_by(source: :viaf, source_id: id)
      record.payload = payload
      record.schema_version = Distiller::SCHEMA_VERSION
      record.fetched_at = Time.current
      record.save!
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      Rails.logger.debug { "Viaf::Cluster: lost the race caching viaf source_id=#{id}: #{e.class}" }
    end
  end
end
