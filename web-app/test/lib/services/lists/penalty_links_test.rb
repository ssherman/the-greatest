require "test_helper"

module Services
  module Lists
    class PenaltyLinksTest < ActiveSupport::TestCase
      setup do
        @list = lists(:books_list)
      end

      test "attach links a static catalogue penalty" do
        penalty = penalties(:books_one_year_penalty)

        result = PenaltyLinks.attach(list: @list, penalty_id: penalty.id)

        assert result.success?
        assert_equal [penalty, true], [result.data[:penalty], result.data[:changed]]
        assert_includes @list.reload.penalties, penalty
      end

      test "attaching twice succeeds, reports no change and keeps one row" do
        penalty = penalties(:books_one_year_penalty)
        PenaltyLinks.attach(list: @list, penalty_id: penalty.id)

        result = PenaltyLinks.attach(list: @list, penalty_id: penalty.id)

        assert result.success?
        assert_equal false, result.data[:changed]
        assert_equal 1, ListPenalty.where(list: @list, penalty: penalty).count
      end

      test "attach refuses a dynamic penalty and names the field that drives it" do
        penalty = penalties(:dynamic_penalty)

        result = PenaltyLinks.attach(list: @list, penalty_id: penalty.id)

        assert_not result.success?
        assert_equal ["Penalty #{penalty.id} is dynamic: set number_of_voters with update_admin_list instead."], result.errors
      end

      test "attach refuses percentage_western as computed from the list's books" do
        penalty = penalties(:books_penalty)

        result = PenaltyLinks.attach(list: @list, penalty_id: penalty.id)

        assert_not result.success?
        assert_equal ["Penalty #{penalty.id} is dynamic: it is computed from the list's books and never attached."], result.errors
      end

      test "attach refuses penalties outside the books catalogue and unknown ids" do
        [penalties(:music_penalty).id, penalties(:user_penalty).id, penalties(:user_books_penalty).id, 0].each do |id|
          result = PenaltyLinks.attach(list: @list, penalty_id: id)

          assert_not result.success?, id.to_s
          assert_equal ["Penalty #{id} is not a books list penalty (see list_admin_penalties)."], result.errors
        end
      end

      test "detach removes the link" do
        penalty = penalties(:static_penalty)
        assert ListPenalty.exists?(list: @list, penalty: penalty)

        result = PenaltyLinks.detach(list: @list, penalty_id: penalty.id)

        assert result.success?
        assert result.data[:changed]
        assert_not ListPenalty.exists?(list: @list, penalty: penalty)
      end

      test "detaching a penalty that is not attached succeeds with no change" do
        result = PenaltyLinks.detach(list: @list, penalty_id: penalties(:books_one_year_penalty).id)

        assert result.success?
        assert_equal false, result.data[:changed]
      end
    end
  end
end
