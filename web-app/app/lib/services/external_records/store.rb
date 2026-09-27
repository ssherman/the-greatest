# frozen_string_literal: true

module Services
  module ExternalRecords
    # Read-through storage for external responses (spec §3): a row held at
    # the current schema_version is used as is; otherwise the caller fetches
    # and writes. Viaf::Cluster predates this and keeps its own copy.
    class Store
      def self.find(source:, source_id:, schema_version:)
        find_all(source: source, source_ids: [source_id], schema_version: schema_version)[source_id.to_s]
      end

      # source_id => row, for the ids held at the current schema_version.
      def self.find_all(source:, source_ids:, schema_version:)
        ids = Array(source_ids).map(&:to_s).uniq
        return {} if ids.empty?

        ::ExternalRecord.where(source: source, source_id: ids, schema_version: schema_version).index_by(&:source_id)
      end

      # Two workers can fetch the same record at once. The unique index on
      # (source, source_id), or the uniqueness validation just before it,
      # settles the race, and the loser returns the winner's row.
      def self.write(source:, source_id:, payload:, raw:, schema_version:)
        record = ::ExternalRecord.find_or_initialize_by(source: source, source_id: source_id.to_s)
        record.assign_attributes(payload: payload, raw_text: raw, schema_version: schema_version, fetched_at: Time.current)
        record.save!
        record
      rescue ActiveRecord::RecordNotUnique
        ::ExternalRecord.find_by!(source: source, source_id: source_id.to_s)
      rescue ActiveRecord::RecordInvalid => e
        raise unless e.record.errors.of_kind?(:source_id, :taken)

        ::ExternalRecord.find_by!(source: source, source_id: source_id.to_s)
      end
    end
  end
end
