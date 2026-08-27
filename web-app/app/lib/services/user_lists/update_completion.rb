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
        UserListItem.transaction do
          item = UserListItem.lock.find(@item.id)
          if item.user_list.completed_on_enabled?
            new_completed_on = parsed_completed_on
            if new_completed_on == :invalid
              invalid_completion_result
            else
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
          else
            completion_not_enabled_result
          end
        end
      rescue ActiveRecord::RecordInvalid => error
        MutationResult.record_invalid(error)
      rescue ActiveRecord::RecordNotUnique
        MutationResult.failure(["Item already in list"])
      rescue ActiveRecord::RecordNotFound
        MutationResult.stale_item
      rescue ActiveRecord::RecordNotSaved, ActiveRecord::RecordNotDestroyed => error
        MutationResult.aborted_mutation(error)
      end

      private

      def parsed_completed_on
        return nil if @completed_on.blank?

        Date.iso8601(@completed_on.to_s)
      rescue Date::Error
        :invalid
      end

      def invalid_completion_result
        MutationResult.failure(["Completion date is invalid"])
      end

      def completion_not_enabled_result
        MutationResult.failure(["Completion dates are not enabled for this list"])
      end
    end
  end
end
