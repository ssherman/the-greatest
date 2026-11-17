module Services
  module UserLists
    # Moves one item to a 1-based position, shifting the rows in between by one
    # in a single UPDATE (a list can hold tens of thousands of items). Counts
    # hidden provisional items too, since positions stay contiguous over all of
    # them. A real move marks the list manually ordered, which is what that flag
    # means; a move to the item's own position changes nothing.
    #
    # Takes no owner lock: callers that need one (UpdateItem) hold OwnerMutation.
    class MoveItem
      def self.call(item:, to_position:)
        new(item: item, to_position: to_position).call
      end

      def initialize(item:, to_position:)
        @item = item
        @to_position = to_position
      end

      def call
        user_list = item.user_list
        count = user_list.user_list_items.count
        unless to_position.is_a?(Integer) && to_position.between?(1, count)
          return MutationResult.failure(["Position must be between 1 and #{count}"])
        end

        UserListItem.transaction(requires_new: true) do
          from = UserListItem.where(id: item.id, user_list_id: user_list.id).pick(:position)
          return MutationResult.stale_item if from.nil?

          shift(user_list, from) unless from == to_position
        end

        item.position = to_position
        item.clear_attribute_changes([:position])
        MutationResult.new(success?: true, data: {item: item, listable: item.listable}, errors: [])
      end

      private

      attr_reader :item, :to_position

      def shift(user_list, from)
        siblings = UserListItem.where(user_list_id: user_list.id)
        if to_position > from
          siblings.where(position: (from + 1)..to_position).update_all("position = position - 1")
        else
          siblings.where(position: to_position..(from - 1)).update_all("position = position + 1")
        end
        UserListItem.where(id: item.id).update_all(position: to_position)
        user_list.update_columns(manually_ordered: true)
        user_list.touch
      end
    end
  end
end
