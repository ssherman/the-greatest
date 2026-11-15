require "test_helper"

module Services
  module Books
    module SeriesEdits
      class GoodreadsIdLockTest < ActiveSupport::TestCase
        test "acquire takes a transaction-scoped advisory lock" do
          ::Books::Series.transaction do
            GoodreadsIdLock.acquire("999001")
            key = ::Books::Series.connection.select_value(
              ::Books::Series.sanitize_sql_array(["SELECT hashtext(?)", "books_series_goodreads_id:999001"])
            )
            held = ::Books::Series.connection.select_value(
              "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid() AND objid = (#{key.to_i} & 4294967295)"
            )
            assert_equal 1, held.to_i
          end
        end

        test "create takes the lock before checking the holder" do
          GoodreadsIdLock.expects(:acquire).with("999002").once
          Create.call(attrs: {"title" => "Locked", "goodreads_series_id" => "999002"})
        end

        test "update takes the lock before checking the holder" do
          GoodreadsIdLock.expects(:acquire).with("999003").once
          Update.call(series: books_series(:asoiaf), attrs: {"goodreads_series_id" => "999003"})
        end

        test "a holder that appears after the pre-check is still refused" do
          other = books_series(:live_target)
          # Simulates the concurrent writer committing while we waited for the lock.
          GoodreadsIdLock.stubs(:acquire).with { other.identifiers.create!(identifier_type: :books_series_goodreads_id, value: "999004", source: :goodreads) }

          assert_no_difference("::Books::Series.count") do
            result = Create.call(attrs: {"title" => "Racer", "goodreads_series_id" => "999004"})
            assert_not result.success?
            assert_equal ["Goodreads series id 999004 already belongs to series #{other.id}."], result.errors
          end
        end
      end
    end
  end
end
