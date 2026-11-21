require "test_helper"

module Services
  module Penalties
    class DetachDynamicTest < ActiveSupport::TestCase
      setup do
        # The fixture already holds one; the validation forbids creating it.
        @dynamic_attachment = list_penalties(:books_list_dynamic_penalty)
      end

      test "dry run reports the attachment and leaves it" do
        result = DetachDynamic.call(dry_run: true)

        assert result.success?
        assert_includes result.data[:list_penalty_ids], @dynamic_attachment.id
        assert ListPenalty.exists?(@dynamic_attachment.id)
      end

      test "applying destroys dynamic attachments only" do
        static_ids = ListPenalty.where(penalty: Penalty.static).pluck(:id).sort

        result = DetachDynamic.call(dry_run: false)

        assert_includes result.data[:list_penalty_ids], @dynamic_attachment.id
        refute ListPenalty.exists?(@dynamic_attachment.id)
        assert_equal static_ids, ListPenalty.where(penalty: Penalty.static).pluck(:id).sort
      end
    end
  end
end
