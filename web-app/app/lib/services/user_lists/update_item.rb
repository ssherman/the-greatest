module Services
  module UserLists
    class UpdateItem
      def self.call(item:, completed_on: :unchanged, position: :unchanged)
        new(item: item, completed_on: completed_on, position: position).call
      end

      def initialize(item:, completed_on:, position:)
        @item = item
        @completed_on = completed_on
        @position = position
      end

      def call
        user_list = item.user_list
        updated = OwnerMutation.call(owner: user_list.user) do |tracker|
          current = item

          unless completed_on == :unchanged
            result = UpdateCompletion.call(item: current, completed_on: completed_on)
            raise BatchFailed.new(result.errors) unless result.success?

            tracker.track(result)
            current = result.data[:item]
          end

          unless position == :unchanged
            begin
              user_list.move_item!(current, position)
            rescue ArgumentError => error
              raise BatchFailed.new([error.message])
            end
          end

          current
        end

        updated.reload
        MutationResult.new(
          success?: true,
          data: {item: updated, listable: updated.listable, outcomes: [{listable: updated.listable, outcome: "updated"}]},
          errors: []
        )
      rescue BatchFailed => error
        MutationResult.failure(error.errors)
      end

      private

      attr_reader :item, :completed_on, :position
    end
  end
end
