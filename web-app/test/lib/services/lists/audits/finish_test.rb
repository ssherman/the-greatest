require "test_helper"

module Services
  module Lists
    module Audits
      class FinishTest < ActiveSupport::TestCase
        setup do
          @user = users(:admin_user)
          @other = users(:regular_user)
          @list = lists(:approved_list)
          @audit = Start.call(user: @user, list: @list).data[:audit]
        end

        def finish(audit: @audit, user: @user, verdict: "verified", note: "Checked", sources: ["https://example.com/a"])
          Finish.call(audit: audit, user: user, verdict: verdict, note: note, sources: sources)
        end

        test "finishes with after snapshot, diff and cleared lease" do
          @list.update!(name: "Renamed")
          result = finish
          audit = result.data[:audit].reload
          assert result.success?
          assert audit.finished?
          assert audit.verified?
          assert_nil audit.lease_expires_at
          assert_equal({"from" => @audit.before["fields"]["name"], "to" => "Renamed"}, audit.field_changes["fields"]["name"])
        end

        test "an unverifiable audit needs no sources" do
          assert finish(verdict: "unverifiable", sources: []).success?
        end

        test "finishing after the lease lapsed still works when nothing superseded it" do
          travel 4.hours do
            assert finish.success?
          end
        end

        test "finishing after another user's start replaced the audit conflicts" do
          travel 4.hours do
            Start.call(user: @other, list: @list)
            result = finish
            assert_not result.success?
            assert result.data[:conflict]
          end
        end

        test "another user cannot finish" do
          result = finish(user: @other)
          assert_not result.success?
          assert result.data[:conflict]
        end

        test "verified without sources is refused" do
          result = finish(sources: [])
          assert_not result.success?
          assert_not result.data[:conflict]
        end

        test "non-URL sources, blank note and bad verdict are refused" do
          assert_not finish(sources: ["not a url"]).success?
          assert_not finish(sources: ["ftp://example.com/x"]).success?
          assert_not finish(sources: "https://example.com").success?
          assert_not finish(note: " ").success?
          assert_not finish(verdict: "maybe").success?
          assert @audit.reload.in_progress?
        end
      end
    end
  end
end
