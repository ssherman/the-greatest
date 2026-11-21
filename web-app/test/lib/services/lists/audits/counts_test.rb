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
      end
    end
  end
end
