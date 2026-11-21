# frozen_string_literal: true

module Services
  module Penalties
    # Copies the reviewed guidance text (config/penalties/guidance.yml) onto the
    # penalty rows. Fills blanks only, so an edit made in the admin form is never
    # overwritten, and refuses a row whose name differs from the entry's so an id
    # that means something else in another database cannot get the wrong rule.
    class LoadGuidance
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(entries:)
        new(entries: entries).call
      end

      def initialize(entries:)
        @entries = entries
      end

      def call
        data = {filled: [], skipped_present: [], mismatched: [], missing: []}
        penalties = ::Penalty.where(id: @entries.map { |e| e["id"] }).index_by(&:id)

        @entries.each do |entry|
          penalty = penalties[entry["id"]]
          if penalty.nil?
            data[:missing] << entry["id"]
          elsif penalty.name != entry["name"]
            data[:mismatched] << {id: penalty.id, expected: entry["name"], actual: penalty.name}
          elsif penalty.guidance.present?
            data[:skipped_present] << penalty.id
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
