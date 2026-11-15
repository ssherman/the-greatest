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

        test "apply links to the merge target" do
          target = books_series(:live_target)
          ::Identifier.create!(identifiable: books_series(:merged_into_live), identifier_type: :books_series_goodreads_id, value: "987100", source: :goodreads)

          facts = ApplySeries.call(book: @book, entries: [entry(id: 987_100, position: "2")])

          assert_equal [@book], target.reload.books.to_a
          assert_equal 0, books_series(:merged_into_live).series_books.count
          assert_equal "linked", facts.first["reason"]
        end

        test "apply skips a junk-deleted series" do
          ::Identifier.create!(identifiable: books_series(:junk_deleted), identifier_type: :books_series_goodreads_id, value: "987101", source: :goodreads)

          assert_no_difference ["::Books::Series.count", "::Books::SeriesBook.count"] do
            facts = ApplySeries.call(book: @book, entries: [entry(id: 987_101)])
            assert_equal "deleted_series", facts.first["reason"]
            assert_not facts.first["applied"]
          end
        end

        test "apply skips a series merged into a deleted target" do
          ::Identifier.create!(identifiable: books_series(:merged_into_dead), identifier_type: :books_series_goodreads_id, value: "987102", source: :goodreads)

          assert_no_difference ["::Books::Series.count", "::Books::SeriesBook.count"] do
            facts = ApplySeries.call(book: @book, entries: [entry(id: 987_102)])
            assert_equal "deleted_series", facts.first["reason"]
          end
        end

        test "apply skips a series deleted after it was resolved" do
          live = ::Books::Series.create!(title: "Raced Series")
          ::Identifier.create!(identifiable: live, identifier_type: :books_series_goodreads_id, value: "987103", source: :goodreads)
          stale = ::Books::Series.find(live.id)
          ::Books::Series.where(id: live.id).update_all(deleted: true)
          ::Books::Series.any_instance.stubs(:canonical).returns(stale)

          assert_no_difference "::Books::SeriesBook.count" do
            facts = ApplySeries.call(book: @book, entries: [entry(id: 987_103)])
            assert_equal "deleted_series", facts.first["reason"]
            assert_not facts.first["applied"]
          end
        end

        test "facts keep entry order when entries are given in descending series id order" do
          ApplySeries.call(book: @other, entries: [entry(id: 987_201, title: "First Made"), entry(id: 987_202, title: "Second Made")])
          lower = series_for(987_201)
          higher = series_for(987_202)
          assert_operator lower.id, :<, higher.id

          facts = ApplySeries.call(book: @book, entries: [entry(id: 987_202, title: "Second Made"), entry(id: 987_201, title: "First Made")])

          assert_equal [987_202, 987_201], facts.map { |f| f["goodreads_series_id"] }
          assert facts.all? { |f| f["applied"] }
          assert_includes higher.reload.books, @book
          assert_includes lower.reload.books, @book
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
