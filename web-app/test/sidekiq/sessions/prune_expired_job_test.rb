require "test_helper"

class Sessions::PruneExpiredJobTest < ActiveSupport::TestCase
  test "deletes expired sessions and keeps live ones" do
    stale_id = sessions(:stale_session).id
    live_id = sessions(:regular_user_session).id

    Sessions::PruneExpiredJob.new.perform

    assert_not Session.exists?(stale_id)
    assert Session.exists?(live_id)
  end
end
