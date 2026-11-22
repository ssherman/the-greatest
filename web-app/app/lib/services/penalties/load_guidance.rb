# frozen_string_literal: true

module Services
  module Penalties
    # Copies the reviewed guidance text (config/penalties/guidance.yml) onto the
    # penalty rows. Fills blanks only by default, so an edit made in the admin form
    # is never overwritten; `overwrite: true` replaces text that differs from the
    # YAML (how an edit to the YAML reaches rows already filled). Refuses a row whose name differs from the entry's so an id
    # that means something else in another database cannot get the wrong rule.
    class LoadGuidance
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(entries:, overwrite: false)
        new(entries: entries, overwrite: overwrite).call
      end

      def initialize(entries:, overwrite: false)
        @entries = entries
        @overwrite = overwrite
      end

      def call
        data = {filled: [], overwritten: [], skipped_present: [], mismatched: [], missing: []}
        penalties = ::Penalty.where(id: @entries.map { |e| e["id"] }).index_by(&:id)

        @entries.each do |entry|
          penalty = penalties[entry["id"]]
          if penalty.nil?
            data[:missing] << entry["id"]
          elsif penalty.name != entry["name"]
            data[:mismatched] << {id: penalty.id, expected: entry["name"], actual: penalty.name}
          elsif penalty.guidance.present? && !(@overwrite && penalty.guidance != entry["guidance"])
            data[:skipped_present] << penalty.id
          elsif penalty.guidance.present?
            penalty.update!(guidance: entry["guidance"])
            data[:overwritten] << penalty.id
          else
            penalty.update!(guidance: entry["guidance"])
            data[:filled] << penalty.id
          end
        end

        Result.new(success?: true, data: data, errors: [])
      end
    end
  end
end
