module Services
  module UserLists
    class RemoveItems
      def self.call(user_list:, listables:)
        new(user_list: user_list, listables: listables).call
      end

      def initialize(user_list:, listables:)
        @user_list = user_list
        @listables = listables
      end

      def call
        outcomes = OwnerMutation.call(owner: user_list.user) do |tracker|
          listables.map { |listable| remove_one(listable, tracker) }
        end
        MutationResult.new(success?: true, data: {outcomes: outcomes}, errors: [])
      rescue BatchFailed => error
        MutationResult.failure(error.errors)
      end

      private

      attr_reader :user_list, :listables

      def remove_one(listable, tracker)
        item = user_list.user_list_items.find_by(listable: listable)
        return {listable: listable, outcome: "not_present"} if item.nil?

        result = RemoveItem.call(item: item)
        raise BatchFailed.new(result.errors) unless result.success?

        tracker.track(result)
        {listable: listable, outcome: "removed"}
      end
    end
  end
end
