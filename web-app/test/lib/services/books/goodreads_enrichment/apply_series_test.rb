require "test_helper"

module Services
  module Books
    module GoodreadsEnrichment
      class ApplySeriesTest < ActiveSupport::TestCase
        setup do
          @book = books_books(:war_and_peace)
          @other = books_books(:crime_and_punishment)
          @gr_id = 987_001
        end

        def entry(id: @gr_id, title: "Zeta Cycle", position: "1")
          {"goodreads_series_id" => id, "title" => title, "position" => position}
        end

        def series_for(id)
          ::Identifier.find_by(identifier_type: :books_series_goodreads_id, value: id.to_s)&.identifiable
        end

        test "the first book creates the series and its identifier" do
          facts = ApplySeries.call(book: @book, entries: [entry])

          series = series_for(@gr_id)
          assert_equal "Zeta Cycle", series.title
          assert_equal "goodreads", series.identifiers.first.source
          assert_equal [@book], series.books.to_a
          assert_equal "created", facts.first["reason"]
          assert facts.first["applied"]
        end

        test "a second book with the same series id links to the same series" do
          ApplySeries.call(book: @book, entries: [entry])
          assert_no_difference "::Books::Series.count" do
            facts = ApplySeries.call(book: @other, entries: [entry(position: "2")])
            assert_equal "linked", facts.first["reason"]
          end
          assert_equal 2, series_for(@gr_id).series_books.count
        end

        test "a plain number sets position and numbered" do
          ApplySeries.call(book: @book, entries: [entry(position: "0.5")])
          link = ::Books::SeriesBook.find_by(book: @book, series: series_for(@gr_id))
          assert_equal BigDecimal("0.5"), link.position
          assert link.numbered
          assert_equal "0.5", link.position_label
        end

        test "a blank position is unnumbered" do
          ApplySeries.call(book: @book, entries: [entry(position: nil)])
          link = ::Books::SeriesBook.find_by(book: @book, series: series_for(@gr_id))
          assert_nil link.position
          refute link.numbered
        end

        test "a non-numeric label is unnumbered and kept as the label" do
          ApplySeries.call(book: @book, entries: [entry(position: "Prequel")])
          link = ::Books::SeriesBook.find_by(book: @book, series: series_for(@gr_id))
          assert_nil link.position
          refute link.numbered
          assert_equal "Prequel", link.position_label
        end

        test "two entries give two links" do
          facts = ApplySeries.call(book: @book, entries: [entry, entry(id: @gr_id + 1, title: "Other Saga")])
          assert_equal 2, ::Books::SeriesBook.where(book: @book, series: [series_for(@gr_id), series_for(@gr_id + 1)]).count
          assert_equal 2, facts.size
        end

        test "a re-run reports already_set and changes nothing" do
          ApplySeries.call(book: @book, entries: [entry])
          assert_no_difference ["::Books::Series.count", "::Books::SeriesBook.count"] do
            facts = ApplySeries.call(book: @book, entries: [entry(position: "9")])
            assert_equal "already_set", facts.first["reason"]
            refute facts.first["applied"]
          end
          link = ::Books::SeriesBook.find_by(book: @book, series: series_for(@gr_id))
          assert_equal "1", link.position_label
        end

        test "same title with different ids stays two series" do
          ApplySeries.call(book: @book, entries: [entry(id: @gr_id), entry(id: @gr_id + 1)])
          refute_equal series_for(@gr_id), series_for(@gr_id + 1)
        end

        test "an entry with no series id is invalid" do
          facts = ApplySeries.call(book: @book, entries: [entry(id: nil)])
          assert_equal "invalid", facts.first["reason"]
          refute facts.first["applied"]
        end
      end
    end
  end
end
