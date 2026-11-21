require "test_helper"

module Services
  module Lists
    module Audits
      class StartTest < ActiveSupport::TestCase
        setup do
          @user = users(:admin_user)
          @other = users(:regular_user)
          @list = lists(:approved_list)
        end

        test "starts an audit on a given list with a snapshot and lease" do
          result = Start.call(user: @user, list: @list)
          audit = result.data[:audit]
          assert result.success?
          assert_not result.data[:resumed]
          assert audit.in_progress?
          assert_equal @user.id, audit.user_id
          assert_equal Snapshot.call(@list), audit.before
          assert_in_delta ListAudit::LEASE.from_now.to_f, audit.lease_expires_at.to_f, 5
        end

        test "resumes the caller's own open audit and renews the lease" do
          first = Start.call(user: @user, list: @list).data[:audit]
          first_lease = first.lease_expires_at
          travel 1.hour do
            result = Start.call(user: @user, list: @list)
            assert result.data[:resumed]
            assert_equal first.id, result.data[:audit].id
            assert_operator result.data[:audit].lease_expires_at, :>, first_lease
          end
        end

        test "with no list, a user holding an open audit on list A is given a different list" do
          first = Start.call(user: @user, list: @list).data[:audit]
          result = Start.call(user: @user)
          assert result.success?
          assert_not result.data[:resumed]
          assert_not_equal first.id, result.data[:audit].id
          assert_not_equal @list.id, result.data[:audit].list_id
        end

        test "a conflict message names a user without an email" do
          nameless = users(:regular_user)
          nameless.update_columns(name: nil, email: "private-address@example.com")
          Start.call(user: nameless, list: @list)
          result = Start.call(user: @user, list: @list)
          assert_includes result.errors.first, "user ##{nameless.id}"
          refute_includes result.errors.first, "private-address"
        end

        test "refuses a list another user is auditing" do
          Start.call(user: @other, list: @list)
          result = Start.call(user: @user, list: @list)
          assert_not result.success?
          assert result.data[:conflict]
          assert_match(/is being audited by/, result.errors.first)
        end

        test "replaces an expired audit, marking the old one released" do
          old = Start.call(user: @other, list: @list).data[:audit]
          travel 4.hours do
            result = Start.call(user: @user, list: @list)
            assert result.success?
            assert_not_equal old.id, result.data[:audit].id
            assert old.reload.released?
            assert_equal "lease expired", old.note
          end
        end

        test "a finished audit is never turned back into a released one" do
          audit = Start.call(user: @other, list: @list).data[:audit]
          travel 4.hours do
            Finish.call(audit: audit, user: @other, verdict: "unverifiable", note: "Agent note", sources: [])
            Start.call(user: @user, list: @list)
            assert audit.reload.finished?
            assert_equal "Agent note", audit.note
          end
        end

        test "without a list takes the head of the queue" do
          head = Queue.relation.first
          result = Start.call(user: @user)
          assert_equal head.id, result.data[:audit].list_id
          assert_equal Queue.remaining, result.data[:remaining]
        end

        test "without a list skips one a concurrent caller took" do
          a = lists(:approved_list)
          b = lists(:high_quality_list)
          Queue.stubs(:relation).returns([a, b])
          Queue.stubs(:remaining).returns(0)
          ListAudit.create!(list: a, user: @other, started_at: Time.current, lease_expires_at: 3.hours.from_now)
          result = Start.call(user: @user)
          assert result.success?
          assert_equal b.id, result.data[:audit].list_id
        end

        test "an empty queue succeeds with no audit" do
          Queue.stubs(:relation).returns([])
          Queue.stubs(:remaining).returns(0)
          result = Start.call(user: @user)
          assert result.success?
          assert_nil result.data[:audit]
        end
      end
    end
  end
end
