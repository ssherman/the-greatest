# frozen_string_literal: true

module Services
  module Books
    module GenrePlan
      # A soft-deleted category in a saved search silently breaks it: included,
      # the search returns nothing; excluded, it does nothing. Removes the ids of
      # genres the plan deleted (spec §6). Merged and retyped ids keep working
      # and are left alone.
      class CriteriaCleaner
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        KEYS = References::KEYS

        def self.call(deleted_ids:)
          new(deleted_ids).call
        end

        def initialize(deleted_ids)
          @deleted = deleted_ids.map(&:to_i).to_set
        end

        def call
          changed = {saved_searches: [], recommendation_configs: []}
          return Result.new(success?: true, data: changed, errors: []) if @deleted.empty?

          {saved_searches: ::Books::SavedSearch, recommendation_configs: ::Books::RecommendationConfig}.each do |key, model|
            model.find_each do |record|
              criteria = (record.criteria || {}).dup
              touched = false
              KEYS.each do |field|
                values = Array(criteria[field])
                kept = values.reject { |v| @deleted.include?(Integer(v.to_s, 10, exception: false)) }
                next if kept.size == values.size

                criteria[field] = kept
                touched = true
              end
              next unless touched

              # update_column: criteria is the owner's data, not a form submission,
              # and nothing else about the record changes.
              record.update_column(:criteria, criteria)
              changed[key] << record.id
            end
          end
          Result.new(success?: true, data: changed, errors: [])
        end
      end
    end
  end
end
