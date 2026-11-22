require "test_helper"

module Services
  module Lists
    module Audits
      class CountsTest < ActiveSupport::TestCase
        test "counts match fixtures plus created rows" do
          before = Counts.call
          assert_equal 1, before[:verified]
          assert_equal 0, before[:unverifiable]
          assert_equal 0, before[:in_progress]
          assert_equal Queue.remaining, before[:not_audited]

          Start.call(user: users(:admin_user), list: lists(:approved_list))
          ListAudit.create!(
            list: lists(:high_quality_list), user: users(:admin_user), status: :finished,
            verdict: :unverifiable, started_at: 1.day.ago, finished_at: 1.day.ago
          )
          after = Counts.call
          assert_equal 1, after[:in_progress]
          assert_equal 1, after[:unverifiable]
          assert_equal before[:not_audited] - 2, after[:not_audited]
        end

        test "a re-audited list counts once, by its latest finished audit" do
          list = lists(:high_quality_list)
          before = Counts.call
          ListAudit.create!(list: list, user: users(:admin_user), status: :finished, verdict: :unverifiable,
            started_at: 3.days.ago, finished_at: 3.days.ago)
          ListAudit.create!(list: list, user: users(:admin_user), status: :finished, verdict: :verified,
            started_at: 1.day.ago, finished_at: 1.day.ago, sources: ["https://example.com"])
          after = Counts.call
          assert_equal before[:verified] + 1, after[:verified]
          assert_equal before[:unverifiable], after[:unverifiable]
        end

        test "in_progress ignores an expired lease" do
          before = Counts.call
          ListAudit.create!(list: lists(:approved_list), user: users(:admin_user), status: :in_progress,
            started_at: 5.hours.ago, lease_expires_at: 1.hour.ago)
          assert_equal before[:in_progress], Counts.call[:in_progress]
        end
      end
    end
  end
end
