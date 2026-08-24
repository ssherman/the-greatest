require "test_helper"

module Actions
  module Admin
    module Books
      class MergeAuthorTest < ActiveSupport::TestCase
        def setup
          @user = users(:admin_user)
          @target = books_authors(:king)
          @source = books_authors(:bachman)

          ::Books::CalculateAuthorRankingsJob.stubs(:perform_async)
        end

        def call(fields)
          Actions::Admin::Books::MergeAuthor.call(
            user: @user, models: [@target], fields: fields
          )
        end

        test "is destructive" do
          assert Actions::Admin::Books::MergeAuthor.destructive?
        end

        test "merges and reports success" do
          result = call({source_author_id: @source.id.to_s, confirm_merge: "1"})

          assert result.success?, result.message
          assert_match(/Richard Bachman/, result.message)
          assert_not ::Books::Author.exists?(@source.id)
        end

        test "reports a warning, not a plain success, when the post-commit follow-up fails" do
          ::Books::Author::Merger.any_instance.stubs(:reindex_target_author)
            .raises(StandardError.new("opensearch down"))

          result = call({source_author_id: @source.id.to_s, confirm_merge: "1"})

          assert result.warning?, result.message
          assert_not result.success?, "a warning must not also report as a plain success"
          assert_match(/Richard Bachman/, result.message)
          assert_match(/source author has been deleted/, result.message)
          assert_match(/could not be scheduled/, result.message)
          assert_match(/opensearch down/, result.message)
          assert_not ::Books::Author.exists?(@source.id), "the merge itself must still have committed"
        end

        test "requires a source author id" do
          result = call({confirm_merge: "1"})

          assert result.error?
          assert_equal "Please select an author to merge.", result.message
          assert ::Books::Author.exists?(@source.id)
        end

        test "requires the confirmation checkbox" do
          result = call({source_author_id: @source.id.to_s})

          assert result.error?
          assert_match(/confirm/i, result.message)
          assert ::Books::Author.exists?(@source.id)
        end

        test "reports a missing source author" do
          result = call({source_author_id: "999999", confirm_merge: "1"})

          assert result.error?
          assert_equal "Author with ID 999999 not found.", result.message
        end

        test "refuses to merge an author with itself" do
          result = call({source_author_id: @target.id.to_s, confirm_merge: "1"})

          assert result.error?
          assert_equal "Cannot merge an author with itself. Please select a different author.", result.message
          assert ::Books::Author.exists?(@target.id)
        end

        test "refuses to act on more than one author" do
          result = Actions::Admin::Books::MergeAuthor.call(
            user: @user,
            models: [@target, @source],
            fields: {source_author_id: @source.id.to_s, confirm_merge: "1"}
          )

          assert result.error?
          assert_match(/single author/, result.message)
        end

        test "surfaces merger failures" do
          ::Books::Author::Merger.any_instance.stubs(:call).returns(
            ::Books::Author::Merger::Result.new(success?: false, data: nil, errors: ["nope"])
          )

          result = call({source_author_id: @source.id.to_s, confirm_merge: "1"})

          assert result.error?
          assert_match(/nope/, result.message)
        end
      end
    end
  end
end
