require "test_helper"

module Services
  module Books
    module GoodreadsEnrichment
      class ApplyTest < ActiveSupport::TestCase
        ISBN13 = "9780140449136"
        ISBN10 = "0140449132"

        setup do
          @book = books_books(:war_and_peace)
          @book.update_columns(first_published_year: nil, page_range: nil)
          @other = books_books(:crime_and_punishment)
          @history = category("Apply Test Historical")
          @russia = category("Apply Test Russian Lit")
        end

        def category(name, type: :genre)
          ::Books::Category.create!(name: name, category_type: type)
        end

        def build_page(**attrs)
          ::Books::GoodreadsPage.new({
            goodreads_book_id: 424_242,
            title: "War and Peace",
            original_publication_year: 1869,
            page_count: 1225,
            format: "Paperback",
            isbn13: ISBN13,
            isbn10: ISBN10,
            genres: ["Apply Test Historical", "Apply Test Russian Lit", "No Such Genre"],
            series: [{"goodreads_series_id" => 770_001, "title" => "Apply Test Cycle", "position" => "1"}],
            description: "Never stored."
          }.merge(attrs))
        end

        def apply(**attrs) = Apply.call(book: @book, page: build_page(**attrs))

        def human_clear!(field_name)
          correction = ::Correction.create!(correctable: @book, status: :resolved, notes: "Cleared.")
          correction.correction_fields.create!(field_name: field_name, status: :applied, new_value: "", applied_at: Time.current)
        end

        def identifier_values(book) = book.identifiers.reload.pluck(:identifier_type, :value).to_set

        test "a full apply on a blank book writes every field and one ledger row" do
          assert_difference -> { @book.enrichments.count }, 1 do
            result = apply

            assert result.success?
            assert_equal %w[first_published_year page_range genres series identifiers].sort, result.data[:applied].sort
          end

          @book.reload
          assert_equal 1869, @book.first_published_year
          assert_equal "1225", @book.page_range
          assert_equal [@history, @russia].sort_by(&:id), @book.categories.where(id: [@history, @russia]).sort_by(&:id)
          assert_equal ["goodreads"], ::CategoryItem.where(item: @book, category: [@history, @russia]).map(&:source).uniq
          assert_equal ["Apply Test Cycle"], @book.series_books.map { |sb| sb.series.title }
          assert_includes identifier_values(@book), ["books_work_goodreads_id", "424242"]
          assert_includes identifier_values(@book), ["books_work_isbn13", ISBN13]
          assert_includes identifier_values(@book), ["books_work_isbn10", ISBN10]

          row = @book.enrichments.order(:id).last
          assert_equal "books.goodreads", row.kind
          assert_equal "goodreads", row.provider
          assert_equal ["https://www.goodreads.com/book/show/424242"], row.citations
          assert row.recognized
          assert row.applied?
          assert_equal ["No Such Genre"], row.facts["genres"]["unmatched"]
        end

        test "a set year is already_set and unchanged" do
          @book.update_columns(first_published_year: 1900)

          result = apply

          assert_equal 1900, @book.reload.first_published_year
          assert_equal "already_set", result.data[:enrichment].facts["first_published_year"]["reason"]
          refute_includes result.data[:applied], "first_published_year"
        end

        test "a human-cleared page_range stays blank" do
          human_clear!("page_range")

          result = apply

          assert_nil @book.reload.page_range.presence
          assert_equal "human_cleared", result.data[:enrichment].facts["page_range"]["reason"]
        end

        test "an ebook or audio format writes no page_range" do
          result = apply(format: "Kindle Edition")

          assert_nil @book.reload.page_range.presence
          refute result.data[:enrichment].facts["page_range"]["applied"]
        end

        test "the default edition's blank page_count is filled with the page_range" do
          edition = ::Books::Edition.create!(book: @book, title: "Penguin", edition_type: :standard)
          @book.update_columns(default_edition_id: edition.id)

          apply

          assert_equal 1225, edition.reload.page_count
        end

        test "a bad ISBN-13 checksum is invalid and the rest is written" do
          result = apply(isbn13: "9780140449137", isbn10: nil)

          facts = result.data[:enrichment].facts["identifiers"]
          assert_equal "invalid", facts.find { |f| f["type"] == "books_work_isbn13" }["reason"]
          assert_includes identifier_values(@book), ["books_work_goodreads_id", "424242"]
          assert_equal 1869, @book.reload.first_published_year
        end

        test "an ASIN is written when it is an ISBN-10 or a 10-character code, and invalid otherwise" do
          apply(isbn13: nil, isbn10: nil, asin: "b000fc0pdc")
          assert_includes identifier_values(@book), ["books_work_asin", "B000FC0PDC"]

          other = Apply.call(book: @other, page: build_page(goodreads_book_id: 424_243, isbn13: nil, isbn10: nil, asin: "0140449133"))
          assert_equal "invalid", other.data[:enrichment].facts["identifiers"].find { |f| f["type"] == "books_work_asin" }["reason"]
        end

        test "an ISBN that Open Library gave another book is not written, the Goodreads id is, and both are flagged" do
          @other.identifiers.create!(identifier_type: "books_work_isbn13", value: ISBN13, source: :open_library)

          assert_difference -> { DuplicateCandidate.count }, 1 do
            result = apply

            reasons = result.data[:enrichment].facts["identifiers"].to_h { |f| [f["type"], f["reason"]] }
            assert_equal "collision", reasons["books_work_isbn13"]
            assert_equal "filled", reasons["books_work_goodreads_id"]
          end

          values = identifier_values(@book)
          assert_includes values, ["books_work_goodreads_id", "424242"]
          refute_includes values, ["books_work_isbn13", ISBN13]
        end

        test "a Goodreads id held by another book writes no identifiers and flags both, other facts still land" do
          @other.identifiers.create!(identifier_type: "books_work_goodreads_id", value: "424242", source: :legacy)

          assert_difference -> { DuplicateCandidate.count }, 1 do
            result = apply

            assert result.data[:enrichment].facts["identifiers"].all? { |f| f["reason"] == "collision" && !f["applied"] }
          end

          values = identifier_values(@book)
          [["books_work_goodreads_id", "424242"], ["books_work_isbn13", ISBN13], ["books_work_isbn10", ISBN10]].each do |pair|
            refute_includes values, pair
          end
          assert_equal 1869, @book.reload.first_published_year
          assert_includes @book.categories, @history
        end

        test "a page listing Fiction and Nonfiction for a book with neither links neither" do
          fiction = category("Fiction")
          nonfiction = category("Nonfiction")

          result = apply(genres: %w[Fiction Nonfiction])

          entries = result.data[:enrichment].facts["genres"]["entries"]
          assert_equal %w[type_conflict type_conflict], entries.map { |e| e["reason"] }
          refute_includes @book.reload.categories, fiction
          refute_includes @book.categories, nonfiction
        end

        test "Fiction is skipped for a book that already holds Nonfiction" do
          fiction = category("Fiction")
          nonfiction = category("Nonfiction")
          ::CategoryItem.create!(category: nonfiction, item: @book, source: :admin)

          result = apply(genres: %w[Fiction])

          assert_equal "type_conflict", result.data[:enrichment].facts["genres"]["entries"].first["reason"]
          refute_includes @book.reload.categories, fiction
        end

        test "an existing category link is already_set and keeps its source" do
          ::CategoryItem.create!(category: @history, item: @book, source: :admin)

          result = apply(genres: ["Apply Test Historical"])

          assert_equal "already_set", result.data[:enrichment].facts["genres"]["entries"].first["reason"]
          assert_equal "admin", ::CategoryItem.find_by(category: @history, item: @book).source
        end

        test "the description is never written" do
          assert_no_difference "Description.count" do
            apply
          end
        end

        test "applying twice records nothing_to_apply the second time and changes no rows" do
          first = apply
          assert first.data[:enrichment].applied?

          counts = -> { [::Identifier.count, ::CategoryItem.count, ::Books::SeriesBook.count, ::Books::Series.count] }
          before = counts.call

          second = apply

          assert_equal before, counts.call
          row = second.data[:enrichment]
          assert row.nothing_to_apply?
          assert_empty second.data[:applied]
          facts = row.facts
          assert_equal "already_set", facts["first_published_year"]["reason"]
          assert_equal "already_set", facts["page_range"]["reason"]
          assert_equal ["already_set", "already_set", "no_match"], facts["genres"]["entries"].map { |e| e["reason"] }
          assert_equal ["already_set"], facts["series"].map { |f| f["reason"] }
          assert facts["identifiers"].all? { |f| f["reason"] == "already_set" }
        end
      end
    end
  end
end
