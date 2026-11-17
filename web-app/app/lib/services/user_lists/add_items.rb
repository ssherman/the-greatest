module Services
  module UserLists
    class AddItems
      def self.call(user_list:, listables:, completed_on: nil, today: Date.current)
        new(user_list: user_list, listables: listables, completed_on: completed_on, today: today).call
      end

      def initialize(user_list:, listables:, completed_on:, today:)
        @user_list = user_list
        @listables = listables
        @completed_on = completed_on
        @today = today
      end

      def call
        if completed_on && !user_list.completed_on_enabled?
          return MutationResult.failure(["Completion dates are not enabled for this list"])
        end

        outcomes = OwnerMutation.call(owner: user_list.user) do |tracker|
          listables.map { |listable| add_one(listable, tracker) }
        end
        MutationResult.new(success?: true, data: {outcomes: outcomes}, errors: [])
      rescue BatchFailed => error
        MutationResult.failure(error.errors)
      end

      private

      attr_reader :user_list, :listables, :completed_on, :today

      def add_one(listable, tracker)
        result = AddItem.call(user_list: user_list, listable: listable, today: today)

        if result.success?
          tracker.track(result)
          outcome = result.data[:transitioned] ? "moved" : "added"
          item = result.data[:item]
        elsif result.errors == ["Item already in list"]
          outcome = "already_present"
          item = user_list.user_list_items.find_by!(listable: listable)
        else
          raise BatchFailed.new(result.errors)
        end

        if completed_on && item.completed_on != completed_on
          outcome = "updated" if outcome == "already_present"
          update = UpdateCompletion.call(item: item, completed_on: completed_on)
          raise BatchFailed.new(update.errors) unless update.success?

          tracker.track(update)
        end

        {listable: listable, outcome: outcome}
      end
    end
  end
end
