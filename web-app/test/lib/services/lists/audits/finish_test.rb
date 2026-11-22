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

        test "our own sites are refused as sources, including subdomains and archived copies" do
          [
            "https://thegreatestbooks.org/lists/122",
            "https://new.thegreatestbooks.org/lists/122",
            "http://www.thegreatestmusic.org/lists/9",
            "https://thegreatest.games/lists/3",
            "https://web.archive.org/web/2020/https://thegreatestbooks.org/lists/122"
          ].each do |url|
            result = finish(sources: ["https://example.com/a", url])
            assert_not result.success?, url
            assert_not result.data[:conflict]
            assert_match(/our own site/, result.errors.join)
          end
          assert @audit.reload.in_progress?
        end

        test "a source that only mentions our name in its path is allowed" do
          assert finish(sources: ["https://example.com/why-thegreatestbooks-is-wrong", "https://notthegreatestbooks.org/x"]).success?
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
