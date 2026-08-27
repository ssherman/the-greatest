require "test_helper"

# == Schema Information
#
# Table name: books_reading_goals
#
#  id           :bigint           not null, primary key
#  description  :text
#  ends_on      :date             not null
#  name         :string           not null
#  public       :boolean          default(FALSE), not null
#  starts_on    :date             not null
#  target_count :integer          not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  user_id      :bigint           not null
#
# Indexes
#
#  index_books_reading_goals_for_public_date_lookup  (user_id,public,starts_on,ends_on)
#  index_books_reading_goals_on_user_id              (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
class Books::ReadingGoalTest < ActiveSupport::TestCase
  test "requires a name, positive target, and ordered dates" do
    goal = Books::ReadingGoal.new(
      user: users(:regular_user), name: "", target_count: 0,
      starts_on: Date.new(2026, 12, 31), ends_on: Date.new(2026, 1, 1)
    )

    refute goal.valid?
    assert_includes goal.errors[:name], "can't be blank"
    assert_includes goal.errors[:target_count], "must be greater than 0"
    assert_includes goal.errors[:ends_on], "must be on or after the start date"
  end

  test "date scopes use inclusive boundaries and stable ordering" do
    today = Date.new(2026, 8, 26)

    assert_equal [books_reading_goals(:active_ending_soon).id, books_reading_goals(:active_ending_later).id],
      Books::ReadingGoal.active_on(today).pluck(:id)
    assert_equal Books::ReadingGoal.upcoming_on(today).pluck(:starts_on, :id),
      Books::ReadingGoal.upcoming_on(today).pluck(:starts_on, :id).sort
    assert_equal Books::ReadingGoal.finished_on(today).pluck(:ends_on, :id),
      Books::ReadingGoal.finished_on(today).pluck(:ends_on, :id).sort.reverse
  end

  test "database constraint rejects a non-positive persisted target" do
    goal = books_reading_goals(:active_ending_soon)

    assert_raises(ActiveRecord::StatementInvalid) do
      goal.update_columns(target_count: 0)
    end
  end

  test "database constraint rejects reversed persisted dates" do
    goal = books_reading_goals(:active_ending_soon)

    assert_raises(ActiveRecord::StatementInvalid) do
      goal.update_columns(ends_on: goal.starts_on - 1.day)
    end
  end
end
