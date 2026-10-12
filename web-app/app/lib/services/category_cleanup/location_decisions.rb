# frozen_string_literal: true

module Services
  module CategoryCleanup
    # Turns one LocationTask answer into decision attributes (spec §4.2 step 2).
    # Names the model gave are resolved to ids here; anything that can't be
    # resolved becomes a `failed` decision so it shows in the report.
    class LocationDecisions
      FICTIONAL_ROOT = "Fictional Location"

      def self.call(**) = new(**).call

      def initialize(entry:, result:, locations:, subjects:)
        @entry = entry
        @result = result
        @locations = locations
        @subjects = subjects
      end

      def call
        case @result[:verdict]
        when "junk" then [decision(:delete)]
        when "not_a_place" then not_a_place
        else place
        end
      end

      private

      def not_a_place
        return [decision(:delete)] unless @result[:retype_to] == "subject"

        name = @result[:canonical_name].presence || @entry.name
        subject_id = @subjects.lookup(name)
        return [decision(:merge, target_category_id: subject_id)] if subject_id

        decisions = [decision(:retype, new_category_type: ::Category.category_types.fetch("subject"))]
        decisions << decision(:rename, new_name: name) if name != @entry.name
        decisions
      end

      def place
        if @result[:merge_into]
          target = @locations.lookup(@result[:merge_into])
          return [failed(:merge, "merge_into #{@result[:merge_into].inspect} matches no location")] if target.nil?
          return [decision(:merge, target_category_id: target)] if target != @entry.id
        end

        name = @result[:canonical_name].presence || @entry.name
        decisions = []
        if name != @entry.name
          clash = @locations.lookup(name)
          return [decision(:merge, target_category_id: clash)] if clash && clash != @entry.id

          decisions << decision(:rename, new_name: name)
        end

        chain = @result[:parent_chain]
        chain = [FICTIONAL_ROOT] if chain.empty? && @result[:verdict] == "fictional_place" && name != FICTIONAL_ROOT
        if chain.any?
          error = chain_error(chain, name)
          decisions << (error ? failed(:set_parent, error, parent_chain: chain) : decision(:set_parent, parent_chain: chain))
        end

        decisions.presence || [decision(:keep)]
      end

      def chain_error(chain, name)
        return "parent chain is longer than #{::Books::Category::MAX_DEPTH - 1} places" if chain.size >= ::Books::Category::MAX_DEPTH

        keys = chain.map { |link| NameNormalizer.twin_key(link) }
        return "parent chain contains an unusable name" if keys.any?(&:nil?)
        return "parent chain repeats a place" if keys.uniq.size != keys.size

        own_key = NameNormalizer.twin_key(name)
        return "parent chain contains the place itself" if own_key && keys.include?(own_key)
        return "parent chain starts at the place itself" if @locations.lookup(chain.first) == @entry.id

        nil
      end

      def decision(action, **attrs)
        {
          category_id: @entry.id, action: action, status: :proposed,
          place_kind: @result[:place_kind], ambiguous: @result[:ambiguous] == true, reason: @result[:reason]
        }.merge(attrs)
      end

      def failed(action, error, **attrs)
        decision(action, **attrs).merge(status: :failed, error: error)
      end
    end
  end
end
