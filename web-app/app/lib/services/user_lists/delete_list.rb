# frozen_string_literal: true

module Services
  module UserLists
    class DeleteList
      def self.call(list:)
        return MutationResult.failure(["A default list cannot be deleted"]) if list.default?

        # One DELETE for the items, not a callback per row: a list can hold
        # thousands. No reading-goal purge: goals count only the read list and
        # default lists cannot be deleted. delete_all skips the item callbacks
        # that touch the user, so the touch is explicit.
        OwnerMutation.call(owner: list.user) do
          ::UserListItem.where(user_list_id: list.id).delete_all
          list.destroy!
          list.user.touch
        end
        MutationResult.new(success?: true, data: {list: list}, errors: [])
      end
    end
  end
end
