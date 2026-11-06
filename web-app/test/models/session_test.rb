require "test_helper"

# == Schema Information
#
# Table name: sessions
#
#  id             :bigint           not null, primary key
#  ip_address     :string
#  last_active_at :datetime         not null
#  user_agent     :string
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  user_id        :bigint           not null
#
# Indexes
#
#  index_sessions_on_user_id  (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
class SessionTest < ActiveSupport::TestCase
  def build_session(last_active_at:, created_at:)
    Session.create!(user: users(:regular_user), last_active_at: last_active_at, created_at: created_at)
  end

  test "expired scope includes a session idle for longer than IDLE_TIMEOUT" do
    session = build_session(last_active_at: 91.days.ago, created_at: 100.days.ago)
    assert_includes Session.expired, session
  end

  test "expired scope includes a session past MAX_LIFETIME even if active today" do
    session = build_session(last_active_at: 1.minute.ago, created_at: (1.year + 1.day).ago)
    assert_includes Session.expired, session
  end

  test "expired scope excludes a live session" do
    session = build_session(last_active_at: 1.day.ago, created_at: 30.days.ago)
    assert_not_includes Session.expired, session
  end

  test "destroying a user destroys their sessions" do
    user = users(:regular_user)
    assert user.sessions.exists?
    assert_difference -> { Session.count }, -user.sessions.count do
      user.destroy
    end
  end
end
