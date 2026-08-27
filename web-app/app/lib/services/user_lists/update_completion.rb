module Services
  module UserLists
    class UpdateCompletion
      def self.call(item:, completed_on:)
        new(item: item, completed_on: completed_on).call
      end

      def initialize(item:, completed_on:)
        @item = item
        @completed_on = completed_on
      end

      def call
        return completion_not_enabled_result unless @item.user_list.completed_on_enabled?

        new_completed_on = parsed_completed_on
        return invalid_completion_result if new_completed_on == :invalid

        UserListItem.transaction do
          item = UserListItem.lock.find(@item.id)
          old_completed_on = item.completed_on
          item.update!(completed_on: new_completed_on)

          MutationResult.new(
            success?: true,
            data: {
              item: item,
              removed_items: [],
              listable: item.listable,
              old_completed_on: old_completed_on,
              new_completed_on: item.completed_on,
              transitioned: false
            },
            errors: []
          )
        end
      rescue ActiveRecord::RecordInvalid => error
        errors = error.record.errors.full_messages
        MutationResult.new(success?: false, data: nil, errors: errors.presence || [error.message])
      rescue ActiveRecord::RecordNotUnique
        MutationResult.new(success?: false, data: nil, errors: ["Item already in list"])
      end

      private

      def parsed_completed_on
        return nil if @completed_on.blank?

        Date.iso8601(@completed_on.to_s)
      rescue Date::Error
        :invalid
      end

      def invalid_completion_result
        MutationResult.new(success?: false, data: nil, errors: ["Completion date is invalid"])
      end

      def completion_not_enabled_result
        MutationResult.new(success?: false, data: nil, errors: ["Completion dates are not enabled for this list"])
      end
    end
  end
end
