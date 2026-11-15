require "test_helper"

module Services
  module Books
    module SeriesEdits
      class MembershipTest < ActiveSupport::TestCase
        setup do
          @series = books_series(:asoiaf)
          @book = books_books(:war_and_peace)
        end

        test "add" do
          result = Membership.add(series: @series, book_id: @book.id, attrs: {"position" => BigDecimal(3), "numbered" => false, "position_label" => "Book 3"})

          assert result.success?
          link = result.data
          assert_equal [@series.id, @book.id], [link.series_id, link.book_id]
          assert_equal BigDecimal(3), link.position
          assert_equal false, link.numbered
          assert_equal "Book 3", link.position_label
        end

        test "add accepts a float position" do
          result = Membership.add(series: @series, book_id: @book.id, attrs: {"position" => 2.5})

          assert_equal 2.5, result.data.reload.position.to_f
        end

        test "add refuses a duplicate" do
          existing = books_series_books(:asoiaf_got).book
          result = Membership.add(series: @series, book_id: existing.id)

          assert_not result.success?
          assert_equal :unprocessable, result.code
          assert_equal ["Book #{existing.id} is already in this series; edit that entry instead."], result.errors
        end

        test "add refuses an unknown book" do
          result = Membership.add(series: @series, book_id: 0)

          assert_not result.success?
          assert_equal :unprocessable, result.code
          assert_equal ["No book 0."], result.errors
        end

        test "update is partial" do
          link = books_series_books(:asoiaf_clash)
          result = Membership.update(series: @series, book_id: link.book_id, attrs: {"numbered" => false})

          assert result.success?
          link.reload
          assert_equal false, link.numbered
          assert_equal BigDecimal("2.0"), link.position
        end

        test "null clears position and position_label" do
          link = books_series_books(:asoiaf_clash)
          link.update!(position_label: "Two")
          Membership.update(series: @series, book_id: link.book_id, attrs: {"position" => nil, "position_label" => nil})

          link.reload
          assert_nil link.position
          assert_nil link.position_label
        end

        test "blank position_label stores nil" do
          link = books_series_books(:asoiaf_clash)
          link.update!(position_label: "Two")
          Membership.update(series: @series, book_id: link.book_id, attrs: {"position_label" => "  "})

          assert_nil link.reload.position_label
        end

        test "remove clears the representative" do
          link = books_series_books(:asoiaf_got)
          @series.update!(representative_book_id: link.book_id)
          result = Membership.remove(series: @series, book_id: link.book_id)

          assert result.success?
          assert_equal link.id, result.data.id
          assert_nil @series.reload.representative_book_id
          assert_not ::Books::SeriesBook.exists?(link.id)
        end

        test "remove keeps a different representative" do
          rep = books_series_books(:asoiaf_got)
          @series.update!(representative_book_id: rep.book_id)
          Membership.remove(series: @series, book_id: books_series_books(:asoiaf_clash).book_id)

          assert_equal rep.book_id, @series.reload.representative_book_id
        end

        test "update and remove of a book not in the series are not_found" do
          [Membership.update(series: @series, book_id: @book.id, attrs: {"numbered" => true}),
            Membership.remove(series: @series, book_id: @book.id)].each do |result|
            assert_not result.success?
            assert_equal :not_found, result.code
            assert_equal ["Book #{@book.id} is not in this series."], result.errors
          end
        end

        test "add, update and remove on a deleted series are unprocessable" do
          series = books_series(:junk_deleted)
          results = [
            Membership.add(series: series, book_id: @book.id),
            Membership.update(series: series, book_id: @book.id, attrs: {}),
            Membership.remove(series: series, book_id: @book.id)
          ]

          results.each do |result|
            assert_not result.success?
            assert_equal :unprocessable, result.code
            assert_equal ["Series #{series.id} is deleted."], result.errors
          end
        end

        test "a merged series reports its target" do
          series = books_series(:merged_into_live)
          result = Membership.add(series: series, book_id: @book.id)

          assert_equal ["Series #{series.id} was merged into series #{series.merged_into_id}."], result.errors
        end
      end
    end
  end
end
