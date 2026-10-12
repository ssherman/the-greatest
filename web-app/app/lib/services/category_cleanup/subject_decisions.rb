# frozen_string_literal: true

module Services
  module CategoryCleanup
    # Turns one SubjectTask answer into decision attributes (spec §4.2 step 4).
    # "is_location" merges into the location of that name when one exists and
    # otherwise retypes; after apply, a retyped category is an undecided
    # location that the next locations propose picks up.
    class SubjectDecisions
      def self.call(**) = new(**).call

      def initialize(entry:, result:, locations:, subjects:)
        @entry = entry
        @result = result
        @locations = locations
        @subjects = subjects
      end

      def call
        case @result[:action]
        when "delete" then [decision(:delete)]
        when "merge" then merge
        when "rename" then rename
        when "is_location" then is_location
        else [decision(:keep)]
        end
      end

      private

      def merge
        target = @subjects.lookup(@result[:merge_into])
        return [failed(:merge, "merge_into #{@result[:merge_into].inspect} matches no subject")] if target.nil?
        return [decision(:keep)] if target == @entry.id

        [decision(:merge, target_category_id: target)]
      end

      def rename
        name = @result[:name]
        return [decision(:keep)] if name.blank? || name == @entry.name

        clash = @subjects.lookup(name)
        return [decision(:merge, target_category_id: clash)] if clash && clash != @entry.id

        [decision(:rename, new_name: name)]
      end

      def is_location
        location_id = @locations.lookup(@entry.name)
        return [decision(:merge, target_category_id: location_id)] if location_id

        [decision(:retype, new_category_type: ::Category.category_types.fetch("location"))]
      end

      def decision(action, **attrs)
        {category_id: @entry.id, action: action, status: :proposed, reason: @result[:reason]}.merge(attrs)
      end

      def failed(action, error, **attrs)
        decision(action, **attrs).merge(status: :failed, error: error)
      end
    end
  end
end
