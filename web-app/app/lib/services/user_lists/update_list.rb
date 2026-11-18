# frozen_string_literal: true

module Services
  module UserLists
    # attrs holds any of :name, :description, :public. A default list keeps its name.
    class UpdateList
      def self.call(list:, attrs:)
        return MutationResult.failure(["A default list cannot be renamed"]) if attrs.key?(:name) && list.default?

        list.update!(attrs)
        MutationResult.new(success?: true, data: {list: list}, errors: [])
      rescue ActiveRecord::RecordInvalid => e
        MutationResult.record_invalid(e)
      end
    end
  end
end
