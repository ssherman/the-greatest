require "test_helper"

module Books
  class GlobalCanonQueryTest < ActiveSupport::TestCase
    setup do
      @rc = ranking_configurations(:books_global)
      @fiction = categories(:books_fiction_genre)
      @nonfiction = categories(:books_nonfiction_genre)
      @next_rank = 0
    end

    test "orders the result by rank" do
      a = rank_book(kind: :fiction)
      b = rank_book(kind: :fiction)

      result = call(total_books: 10, nonfiction_percentage: 0)

      assert_equal [a.id, b.id], result.ranked_items.map(&:item_id)
    end

    test "takes at most max_books_per_country from one country" do
      france = country("France")
      4.times { rank_book(kind: :fiction, country: france) }

      result = call(total_books: 10, nonfiction_percentage: 0, max_books_per_country: 3)

      assert_equal 3, result.delivered
      assert_equal 1, result.blocked_by_country
    end

    test "takes at most one book per author" do
      author = author("Repeat Author")
      3.times { rank_book(kind: :fiction, author: author) }

      result = call(total_books: 10, nonfiction_percentage: 0)

      assert_equal 1, result.delivered
      assert_equal 2, result.blocked_by_author
    end

    test "caps books with no country in a single bucket, as legacy does" do
      4.times { rank_book(kind: :fiction, country: nil) }

      result = call(total_books: 10, nonfiction_percentage: 0, max_books_per_country: 2)

      assert_equal 2, result.delivered
    end

    test "fiction consumes country slots before the non-fiction pass runs" do
      # Both fiction books outrank both non-fiction books, and all four share a
      # country whose cap is 1. Fiction-first means the fiction book wins the
      # slot and the non-fiction quota goes unfilled. If the passes were
      # reordered, the non-fiction book would take it instead -- so this test
      # fails against a flipped implementation rather than passing either way.
      japan = country("Japan")
      fiction_book = rank_book(kind: :fiction, country: japan)
      rank_book(kind: :nonfiction, country: japan)

      result = call(total_books: 2, nonfiction_percentage: 50, max_books_per_country: 1)

      assert_equal [fiction_book.id], result.ranked_items.map(&:item_id)
    end

    test "never returns a blocked book" do
      blocked = rank_book(kind: :fiction, id: Books::GlobalCanonQuery::BLOCKED_BOOK_IDS.first)
      allowed = rank_book(kind: :fiction)

      result = call(total_books: 10, nonfiction_percentage: 0)

      assert_equal [allowed.id], result.ranked_items.map(&:item_id)
      refute_includes result.ranked_items.map(&:item_id), blocked.id
    end

    test "0 percent yields no non-fiction" do
      fiction_book = rank_book(kind: :fiction)
      rank_book(kind: :nonfiction)

      result = call(total_books: 10, nonfiction_percentage: 0)

      assert_equal [fiction_book.id], result.ranked_items.map(&:item_id)
    end

    test "100 percent yields no fiction" do
      rank_book(kind: :fiction)
      nonfiction_book = rank_book(kind: :nonfiction)

      result = call(total_books: 10, nonfiction_percentage: 100)

      assert_equal [nonfiction_book.id], result.ranked_items.map(&:item_id)
    end

    test "a book in neither category never appears, at either extreme" do
      uncategorised = rank_book(kind: nil)

      [0, 50, 100].each do |percentage|
        result = call(total_books: 10, nonfiction_percentage: percentage)
        refute_includes result.ranked_items.map(&:item_id), uncategorised.id,
          "uncategorised book appeared at #{percentage}% non-fiction"
      end
    end

    test "an excluded genre removes its books" do
      poetry = ::Books::Category.create!(name: "Poetry", slug: "poetry", category_type: :genre)
      excluded = rank_book(kind: :fiction)
      ::CategoryItem.create!(category: poetry, item: excluded)
      kept = rank_book(kind: :fiction)

      result = call(total_books: 10, nonfiction_percentage: 0, excluded_genres: [poetry])

      assert_equal [kept.id], result.ranked_items.map(&:item_id)
    end

    test "reports the requested and delivered counts" do
      rank_book(kind: :fiction)

      result = call(total_books: 50, nonfiction_percentage: 0)

      assert_equal 50, result.requested
      assert_equal 1, result.delivered
    end

    test "returns nothing when the fiction category is missing" do
      # A public page must not 500 on a data problem. The short-list note
      # explains the empty result instead.
      @fiction.destroy!
      rank_book(kind: :nonfiction)

      result = call(total_books: 10, nonfiction_percentage: 0)

      assert_equal 0, result.delivered
    end

    test "spends the lowest-position author, not the first-created one" do
      first_author = author("First Author")
      second_author = author("Second Author")

      book_a = rank_book(kind: :fiction, author: nil)
      # The position-2 join row is created FIRST, so it has the lower id. Only
      # `order(:position, :id)` picks first_author here; `order(:id)` would pick
      # second_author and book_b below would then be selected.
      ::Books::BookAuthor.create!(book: book_a, author: second_author, position: 2, role: :author)
      ::Books::BookAuthor.create!(book: book_a, author: first_author, position: 1, role: :author)

      book_b = rank_book(kind: :fiction, author: first_author)

      result = call(total_books: 10, nonfiction_percentage: 0)

      assert_equal [book_a.id], result.ranked_items.map(&:item_id)
      refute_includes result.ranked_items.map(&:item_id), book_b.id
    end

    test "spends the lowest-id country when a book has two" do
      first_country = country("First Country")
      second_country = country("Second Country")

      book_a = rank_book(kind: :fiction, country: first_country)
      ::Books::BookCountry.create!(book: book_a, country: second_country)

      # book_b shares first_country under a cap of 1. It is blocked ONLY if
      # book_a spent first_country; had book_a spent second_country, first_country
      # would still be free and book_b would be selected.
      book_b = rank_book(kind: :fiction, country: first_country)

      result = call(total_books: 10, nonfiction_percentage: 0, max_books_per_country: 1)

      assert_equal [book_a.id], result.ranked_items.map(&:item_id)
      refute_includes result.ranked_items.map(&:item_id), book_b.id
    end

    private

    def call(total_books:, nonfiction_percentage:, max_books_per_country: 10, excluded_genres: [])
      settings = ::Books::GlobalCanonParams::Settings.new(
        total_books: total_books,
        nonfiction_percentage: nonfiction_percentage,
        max_books_per_country: max_books_per_country,
        excluded_genres: excluded_genres
      )
      ::Books::GlobalCanonQuery.call(ranking_configuration: @rc, settings: settings)
    end

    def rank_book(kind:, country: :auto, author: :auto, id: nil)
      @next_rank += 1
      book = ::Books::Book.create!(id: id, title: "Canon Book #{@next_rank}")

      resolved_country = (country == :auto) ? country("Country #{@next_rank}") : country
      ::Books::BookCountry.create!(book: book, country: resolved_country) if resolved_country

      resolved_author = (author == :auto) ? author("Author #{@next_rank}") : author
      ::Books::BookAuthor.create!(book: book, author: resolved_author, position: 1, role: :author) if resolved_author

      category = {fiction: @fiction, nonfiction: @nonfiction}[kind]
      ::CategoryItem.create!(category: category, item: book) if category

      ::RankedItem.create!(item: book, ranking_configuration: @rc, rank: @next_rank, score: 10_000 - @next_rank)
      book
    end

    def country(name)
      ::Books::Country.create!(name: name, slug: name.parameterize, labels: [])
    end

    def author(name)
      ::Books::Author.create!(name: name)
    end
  end
end
