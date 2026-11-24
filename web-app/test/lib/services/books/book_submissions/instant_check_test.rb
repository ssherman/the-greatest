require "test_helper"

module Services
  module Books
    module BookSubmissions
      class InstantCheckTest < ActiveSupport::TestCase
        setup do
          @author = ::Books::Author.create!(name: "Ursula Instantcheck")
          @config = ranking_configurations(:books_global)
        end

        def make_book(title: "Instant Check Title #{SecureRandom.hex(3)}", provisional: false, author: @author)
          book = ::Books::Book.create!(title: title, provisional: provisional)
          ::Books::BookAuthor.create!(book: book, author: author) if author
          book
        end

        def hold(record, type, value, source: :open_library)
          Identifier.create!(identifiable: record, identifier_type: type, value: value, source: source)
        end

        def check(**attributes)
          InstantCheck.call(attributes: attributes)
        end

        def ids(result) = result.data[:books].map(&:id)

        test "finds a book by Goodreads id, comparing the id as a string" do
          book = make_book
          hold(book, :books_work_goodreads_id, "4242")
          assert_equal [book.id], ids(check(input_method: "goodreads", goodreads_book_id: 4242))
        end

        test "finds a book through an edition's Goodreads id and answers with the edition's book" do
          book = make_book
          edition = ::Books::Edition.create!(book: book, title: "An Edition")
          hold(edition, :books_edition_goodreads_id, "5151")
          assert_equal [book.id], ids(check(input_method: "goodreads", goodreads_book_id: 5151))
        end

        test "finds a book by ISBN-13 on the book and on an edition" do
          direct = make_book
          hold(direct, :books_work_isbn13, "9780061054884")
          via_edition = make_book
          edition = ::Books::Edition.create!(book: via_edition, title: "Ed")
          hold(edition, :books_edition_isbn13, "9780140449136")
          assert_equal [direct.id], ids(check(input_method: "isbn", isbn13: "9780061054884"))
          assert_equal [via_edition.id], ids(check(input_method: "isbn", isbn13: "9780140449136"))
        end

        test "finds a book by ISBN-10 on the book and on an edition" do
          direct = make_book
          hold(direct, :books_work_isbn10, "0061054887")
          via_edition = make_book
          edition = ::Books::Edition.create!(book: via_edition, title: "Ed")
          hold(edition, :books_edition_isbn10, "0140449132")
          assert_equal [direct.id], ids(check(input_method: "isbn", isbn10: "0061054887"))
          assert_equal [via_edition.id], ids(check(input_method: "isbn", isbn10: "0140449132"))
        end

        test "an ISBN-10 alone hits a book that holds only the ISBN-13" do
          book = make_book
          hold(book, :books_work_isbn13, "9780061054884")
          assert_equal [book.id], ids(check(input_method: "isbn", isbn10: "0061054887"))
        end

        test "finds a book by ASIN on the book and on an edition" do
          direct = make_book
          hold(direct, :books_work_asin, "B000FC11JE")
          via_edition = make_book
          edition = ::Books::Edition.create!(book: via_edition, title: "Ed")
          hold(edition, :books_edition_asin, "B000FC1AAA")
          assert_equal [direct.id], ids(check(input_method: "amazon", asin: "B000FC11JE"))
          assert_equal [via_edition.id], ids(check(input_method: "amazon", asin: "B000FC1AAA"))
        end

        test "an ASIN that is an ISBN-10 hits an ISBN row" do
          book = make_book
          hold(book, :books_work_isbn10, "0061054887")
          assert_equal [book.id], ids(check(input_method: "amazon", asin: "0061054887"))
        end

        test "ignores identifiers whose source is legacy or nil" do
          legacy = make_book
          hold(legacy, :books_work_isbn13, "9780061054884", source: :legacy)
          unsourced = make_book
          hold(unsourced, :books_work_isbn13, "9780061054884", source: nil)
          assert_empty ids(check(input_method: "isbn", isbn13: "9780061054884"))
        end

        test "a reader's own earlier submission counts as a source" do
          book = make_book
          hold(book, :books_work_isbn13, "9780061054884", source: :user_submission)
          assert_equal [book.id], ids(check(input_method: "isbn", isbn13: "9780061054884"))
        end

        test "two holders return both and four return three" do
          books = Array.new(4) { make_book }
          books.first(2).each { |book| hold(book, :books_work_isbn13, "9780061054884") }
          assert_equal books.first(2).map(&:id).sort, ids(check(input_method: "isbn", isbn13: "9780061054884")).sort

          books.last(2).each { |book| hold(book, :books_work_isbn13, "9780061054884") }
          assert_equal 3, ids(check(input_method: "isbn", isbn13: "9780061054884")).size
        end

        test "a book holding several matching identifiers appears once" do
          book = make_book
          hold(book, :books_work_isbn13, "9780061054884")
          hold(book, :books_work_isbn10, "0061054887")
          assert_equal [book.id], ids(check(input_method: "isbn", isbn13: "9780061054884", isbn10: "0061054887"))
        end

        test "matches title and authors exactly, case and spacing aside" do
          book = make_book(title: "The Instant Dispossessed")
          make_book(title: "The Instant Dispossessed", author: ::Books::Author.create!(name: "Someone Else"))
          result = check(input_method: "title_authors", typed_title: "the  instant DISPOSSESSED", typed_author_names: ["Ursula Instantcheck"])
          assert_equal [book.id], ids(result)
        end

        test "a different author does not match" do
          make_book(title: "The Instant Dispossessed")
          result = check(input_method: "title_authors", typed_title: "The Instant Dispossessed", typed_author_names: ["Nobody Else"])
          assert_empty ids(result)
        end

        test "a title with no authors matches nothing" do
          make_book(title: "The Instant Dispossessed")
          assert_empty ids(check(input_method: "title_authors", typed_title: "The Instant Dispossessed", typed_author_names: []))
        end

        test "a provisional book is returned" do
          book = make_book(provisional: true)
          hold(book, :books_work_isbn13, "9780061054884")
          assert_equal [book.id], ids(check(input_method: "isbn", isbn13: "9780061054884"))
        end

        test "a catalog book comes before a provisional one even when the provisional one is ranked and older" do
          provisional = make_book(provisional: true)
          catalog = make_book
          RankedItem.create!(item: provisional, ranking_configuration: @config, rank: 1, score: 1)
          [provisional, catalog].each { |book| hold(book, :books_work_isbn13, "9780061054884") }
          assert_equal [catalog.id, provisional.id], ids(check(input_method: "isbn", isbn13: "9780061054884"))
        end

        test "ranked books come first, lowest rank first, then unranked, whatever their ids" do
          unranked = make_book
          rank_nine = make_book
          rank_two = make_book
          RankedItem.create!(item: rank_nine, ranking_configuration: @config, rank: 9_001, score: 1)
          RankedItem.create!(item: rank_two, ranking_configuration: @config, rank: 2, score: 1)
          [unranked, rank_nine, rank_two].each { |book| hold(book, :books_work_isbn13, "9780061054884") }
          assert_equal [rank_two.id, rank_nine.id, unranked.id], ids(check(input_method: "isbn", isbn13: "9780061054884"))
        end

        test "a rank in another configuration does not count" do
          other = ranking_configurations(:books_user)
          plain = make_book
          elsewhere = make_book
          RankedItem.create!(item: elsewhere, ranking_configuration: other, rank: 1, score: 1)
          RankedItem.create!(item: plain, ranking_configuration: @config, rank: 5, score: 1)
          [plain, elsewhere].each { |book| hold(book, :books_work_isbn13, "9780061054884") }
          assert_equal [plain.id, elsewhere.id], ids(check(input_method: "isbn", isbn13: "9780061054884"))
        end

        test "equal standing falls back to the lower id" do
          first = make_book
          second = make_book
          [second, first].each { |book| hold(book, :books_work_isbn13, "9780061054884") }
          assert_equal [first.id, second.id], ids(check(input_method: "isbn", isbn13: "9780061054884"))
        end

        test "without a primary configuration every book is unranked" do
          ::Books::RankingConfiguration.stubs(:default_primary).returns(nil)
          first = make_book
          second = make_book
          [second, first].each { |book| hold(book, :books_work_isbn13, "9780061054884") }
          assert_equal [first.id, second.id], ids(check(input_method: "isbn", isbn13: "9780061054884"))
        end

        test "authors are preloaded so rendering them costs no extra query" do
          books = Array.new(3) { make_book }
          books.each { |book| hold(book, :books_work_isbn13, "9780061054884") }
          result = check(input_method: "isbn", isbn13: "9780061054884")
          queries = 0
          counter = ->(*, payload) { queries += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) }
          ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
            result.data[:books].each { |book| book.authors.map(&:name) }
          end
          assert_equal 0, queries
        end

        test "no match is a success with no books" do
          result = check(input_method: "isbn", isbn13: "9780061054884")
          assert result.success?
          assert_empty result.data[:books]
        end

        test "calls nothing outside the database" do
          ::Books::OpenLibrary::Client.expects(:new).never
          ::Services::Ai::Tasks::Matching::SelectCandidateTask.expects(:new).never
          book = make_book(title: "Offline Title")
          hold(book, :books_work_isbn13, "9780061054884")
          check(input_method: "isbn", isbn13: "9780061054884")
          check(input_method: "title_authors", typed_title: "Offline Title", typed_author_names: ["Ursula Instantcheck"])
        end
      end
    end
  end
end
