# frozen_string_literal: true

module DataImporters
  module Books
    module Author
      # Query object for ::Books::Author imports. `name` is required unless an
      # Open Library author key is given (a key-only import takes its name
      # from Open Library). `work_titles` is context for the AI prompt and
      # the audit pages; it is never matched on.
      class ImportQuery < DataImporters::ImportQuery
        attr_reader :name, :open_library_author_key, :birth_year, :death_year, :alternate_names, :work_titles

        SNAPSHOT_KEYS = %i[name open_library_author_key birth_year death_year alternate_names work_titles].freeze

        # Rebuilds a query from the hash FinderBase#query_snapshot stored on
        # match_decisions.query. Unknown keys are dropped so an older row
        # still loads. The audit page's Re-check is the caller.
        def self.from_snapshot(snapshot)
          new(**snapshot.to_h.symbolize_keys.slice(*SNAPSHOT_KEYS))
        end

        def initialize(name: nil, open_library_author_key: nil, birth_year: nil, death_year: nil, alternate_names: [], work_titles: [])
          @name = name
          @open_library_author_key = open_library_author_key.presence
          @birth_year = birth_year
          @death_year = death_year
          @alternate_names = Array(alternate_names).compact_blank.map(&:to_s).uniq
          @work_titles = Array(work_titles).compact_blank.map(&:to_s).uniq
        end

        def valid?
          validation_errors.empty?
        end

        def validate!
          errors = validation_errors
          raise ArgumentError, errors.join(", ") if errors.any?
        end

        private

        def validation_errors
          errors = []
          errors << "Name is required when no Open Library author key is provided" if name.blank? && open_library_author_key.blank?
          errors << "Name must be a string" if name.present? && !name.is_a?(String)
          errors << "Birth year must be an integer" if birth_year.present? && !birth_year.is_a?(Integer)
          errors << "Death year must be an integer" if death_year.present? && !death_year.is_a?(Integer)
          errors
        end
      end
    end
  end
end
