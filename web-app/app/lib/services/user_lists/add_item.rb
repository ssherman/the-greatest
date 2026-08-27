module Services
  module UserLists
    class AddItem
      def self.call(user_list:, listable:, today: Date.current)
        new(user_list: user_list, listable: listable, today: today).call
      end

      def initialize(user_list:, listable:, today:)
        @user_list = user_list
        @listable = listable
        @today = today
      end

      def call
        UserListItem.transaction do
          memberships = locked_memberships
          target = memberships.find { |membership| membership.user_list_id == user_list.id }
          sources = memberships.reject { |membership| membership.user_list_id == user_list.id }

          return duplicate_result if target.present? && sources.empty?

          target ||= UserListItem.new(user_list: user_list, listable: listable)
          old_completed_on = target.completed_on
          target.completed_on = today if sources.any? && user_list.completed_on_enabled? && target.completed_on.nil?

          sources.each(&:destroy!)
          target.save! if target.new_record? || target.changed?

          success_result(target: target, removed_items: sources, old_completed_on: old_completed_on)
        end
      rescue ActiveRecord::RecordInvalid => error
        record_invalid_result(error)
      rescue ActiveRecord::RecordNotUnique
        duplicate_result
      end

      private

      attr_reader :user_list, :listable, :today

      def locked_memberships
        UserListItem.where(
          user_list_id: transition_list_ids,
          listable_type: listable.class.base_class.name,
          listable_id: listable.id
        ).order(:id).lock.to_a
      end

      def transition_list_ids
        [user_list.id] + source_list_ids
      end

      def source_list_ids
        source_types = user_list.completion_transition_source_types
        return [] if source_types.empty?

        user_list.class.where(user_id: user_list.user_id, list_type: source_types).pluck(:id)
      end

      def success_result(target:, removed_items:, old_completed_on:)
        MutationResult.new(
          success?: true,
          data: {
            item: target,
            removed_items: removed_items,
            listable: target.listable,
            old_completed_on: old_completed_on,
            new_completed_on: target.completed_on,
            transitioned: removed_items.any?
          },
          errors: []
        )
      end

      def duplicate_result
        MutationResult.new(success?: false, data: nil, errors: ["Item already in list"])
      end

      def record_invalid_result(error)
        errors = error.record.errors.full_messages
        MutationResult.new(success?: false, data: nil, errors: errors.presence || [error.message])
      end
    end
  end
end
