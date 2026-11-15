require "test_helper"

module Services
  module Books
    module SeriesEdits
      class CreateTest < ActiveSupport::TestCase
        test "create with a title" do
          result = Create.call(attrs: {"title" => "New Saga"})

          assert result.success?
          assert_equal "New Saga", result.data.title
          assert result.data.persisted?
        end

        test "create stores a goodreads id as an admin-sourced identifier" do
          result = Create.call(attrs: {"title" => "With Id", "goodreads_series_id" => "777001"})

          assert result.success?
          identifier = result.data.identifiers.sole
          assert_equal "777001", identifier.value
          assert_equal "books_series_goodreads_id", identifier.identifier_type
          assert_equal "admin", identifier.source
        end

        test "create refuses a goodreads id another series holds" do
          holder = books_series(:asoiaf)
          holder.identifiers.create!(identifier_type: :books_series_goodreads_id, value: "777002", source: :goodreads)

          assert_no_difference("::Books::Series.count") do
            result = Create.call(attrs: {"title" => "Dup", "goodreads_series_id" => "777002"})
            assert_not result.success?
            assert_equal :unprocessable, result.code
            assert_equal ["Goodreads series id 777002 already belongs to series #{holder.id}."], result.errors
          end
        end

        test "create refuses a goodreads id held by a soft-deleted series" do
          holder = books_series(:junk_deleted)
          holder.identifiers.create!(identifier_type: :books_series_goodreads_id, value: "777003", source: :goodreads)

          assert_no_difference("::Books::Series.count") do
            result = Create.call(attrs: {"title" => "Dup", "goodreads_series_id" => "777003"})
            assert_not result.success?
          end
        end

        test "create without a title is unprocessable" do
          assert_no_difference("::Books::Series.count") do
            result = Create.call(attrs: {"title" => " "})
            assert_not result.success?
            assert_equal :unprocessable, result.code
          end
        end
      end
    end
  end
end
