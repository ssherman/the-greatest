module Services
  module UserLists
    # Undo for a removal: puts the item back with its old completion date and
    # position, all in one OwnerMutation so a failure restores everything.
    #
    # AddItem would take the book off a transition-source list (Reading, when
    # restoring to Read) and stamp today's date. The removal never did that, so
    # if the book is on such a list now, the member put it there after removing
    # it; we refuse rather than silently move it. The completion date is always
    # set back explicitly, nil included, undoing AddItem's stamp.
    class RestoreItem
      def self.call(user_list:, listable:, position:, completed_on:)
        new(user_list: user_list, listable: listable, position: position, completed_on: completed_on).call
      end

      def initialize(user_list:, listable:, position:, completed_on:)
        @user_list = user_list
        @listable = listable
        @position = position
        @completed_on = completed_on
      end

      def call
        item = OwnerMutation.call(owner: user_list.user) do |tracker|
          raise BatchFailed.new("Already back on this list") if user_list.user_list_items.exists?(listable: listable)
          raise BatchFailed.new("Already on another list, so it was not moved back") if on_source_list?

          added = AddItem.call(user_list: user_list, listable: listable)
          raise BatchFailed.new(added.errors) unless added.success?

          tracker.track(added)
          current = added.data[:item]

          if user_list.completed_on_enabled?
            completion = UpdateCompletion.call(item: current, completed_on: completed_on)
            raise BatchFailed.new(completion.errors) unless completion.success?

            tracker.track(completion)
            current = completion.data[:item]
          end

          target = position.to_i.clamp(1, [user_list.user_list_items.count, 1].max)
          unless target == current.reload.position
            moved = MoveItem.call(item: current, to_position: target)
            raise BatchFailed.new(moved.errors) unless moved.success?
          end

          current
        end

        item.reload
        MutationResult.new(success?: true, data: {item: item}, errors: [])
      rescue BatchFailed => error
        MutationResult.failure(error.errors)
      end

      private

      attr_reader :user_list, :listable, :position, :completed_on

      def on_source_list?
        source_types = user_list.completion_transition_source_types
        return false if source_types.empty?

        source_ids = user_list.class.where(user_id: user_list.user_id, list_type: source_types).pluck(:id)
        UserListItem.exists?(user_list_id: source_ids, listable_type: listable.class.base_class.name, listable_id: listable.id)
      end
    end
  end
end
