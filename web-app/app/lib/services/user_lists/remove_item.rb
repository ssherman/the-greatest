module Services
  module UserLists
    class RemoveItem
      def self.call(item:)
        new(item: item).call
      end

      def initialize(item:)
        @item = item
      end

      def call
        UserListItem.transaction do
          item = UserListItem.lock.find(@item.id)
          old_completed_on = item.completed_on
          item.destroy!

          MutationResult.new(
            success?: true,
            data: {
              item: item,
              removed_items: [],
              listable: item.listable,
              old_completed_on: old_completed_on,
              new_completed_on: nil,
              transitioned: false
            },
            errors: []
          )
        end
      end
    end
  end
end
