require "test_helper"

module Services
  module Lists
    module Audits
      class ReleaseTest < ActiveSupport::TestCase
        setup do
          @user = users(:admin_user)
          @other = users(:regular_user)
          @audit = Start.call(user: @user, list: lists(:approved_list)).data[:audit]
        end

        test "the holder can release, with a note" do
          result = Release.call(audit: @audit, user: @user, note: "giving up")
          assert result.success?
          assert @audit.reload.released?
          assert_equal "giving up", @audit.note
          assert_not_nil @audit.finished_at
        end

        test "another user cannot" do
          result = Release.call(audit: @audit, user: @other)
          assert_not result.success?
          assert @audit.reload.in_progress?
        end

        test "an admin can release someone else's audit" do
          assert Release.call(audit: @audit, user: @other, admin: true).success?
          assert @audit.reload.released?
        end

        test "a finished audit cannot be released" do
          result = Release.call(audit: list_audits(:books_verified_audit), user: @user, admin: true)
          assert_not result.success?
        end
      end
    end
  end
end
