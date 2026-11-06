require "test_helper"

module Services
  module AlternateTitles
    class BackfillTest < ActiveSupport::TestCase
      setup do
        @book = books_books(:war_and_peace)
        ::AlternateTitle.where(titleable: @book).delete_all
        @book.update_columns(alternate_titles: ["Voyna i mir", "Guerre et paix"])
      end

      test "creates one legacy row per array element" do
        assert_equal 2, Backfill.call(@book)
        rows = @book.alternate_title_records.order(:id)
        assert_equal ["Voyna i mir", "Guerre et paix"], rows.pluck(:title)
        assert rows.all?(&:from_legacy?)
        assert rows.all?(&:kept?)
        assert_equal ["Voyna i mir", "Guerre et paix"], @book.reload.alternate_titles
      end

      test "is idempotent" do
        Backfill.call(@book)
        assert_no_difference -> { ::AlternateTitle.count } do
          assert_equal 0, Backfill.call(@book)
        end
      end

      test "collapses spellings that normalize alike" do
        @book.update_columns(alternate_titles: ["Voyna i mir", "VOYNA I MIR"])
        assert_equal 1, Backfill.call(@book)
        assert_equal 1, @book.alternate_title_records.count
      end

      test "never touches an existing removed row" do
        removed = ::AlternateTitle.create!(titleable: @book, title: "Guerre et paix", source: :legacy, status: :removed)
        assert_equal 1, Backfill.call(@book)
        assert removed.reload.removed?
        assert_equal 1, @book.alternate_title_records.where(normalized_title: removed.normalized_title).count
      end

      test "all backfills every book with alternate_titles" do
        other = books_books(:crime_and_punishment)
        ::AlternateTitle.where(titleable: other).delete_all
        other.update_columns(alternate_titles: ["Prestuplenie i nakazanie"])
        total = Backfill.all
        assert_operator total, :>=, 3
        assert_equal 2, @book.alternate_title_records.count
        assert_equal 1, other.alternate_title_records.count
      end
    end
  end
end
