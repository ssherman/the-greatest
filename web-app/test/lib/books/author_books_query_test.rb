require "test_helper"

module Books
  class AuthorBooksQueryTest < ActiveSupport::TestCase
    setup do
      @config = ranking_configurations(:books_global)
      @other_config = ranking_configurations(:books_inherited)
      @author = ::Books::Author.create!(name: "Query Author")
    end

    def write_book(title, year: nil, role: :author, provisional: false)
      book = ::Books::Book.create!(title: title, first_published_year: year, provisional: provisional)
      ::Books::BookAuthor.create!(book: book, author: @author, role: role)
      book
    end

    def rank(book, position, config: @config)
      RankedItem.create!(item: book, ranking_configuration: config, rank: position, score: 100 - position)
    end

    test "ranked books come first in rank order, then unranked by first_published_year then title, each carrying ranked_position" do
      rank_two = write_book("Second Ranked", year: 1900)
      rank_one = write_book("First Ranked", year: 1950)
      old_unranked = write_book("Old Unranked", year: 1800)
      b_unranked = write_book("B Same Year", year: 1850)
      a_unranked = write_book("A Same Year", year: 1850)
      undated = write_book("Undated")
      rank(rank_two, 2)
      rank(rank_one, 1)

      books = Books::AuthorBooksQuery.call(author: @author, ranking_configuration: @config).to_a

      assert_equal [rank_one, rank_two, old_unranked, a_unranked, b_unranked, undated].map(&:id), books.map(&:id)
      assert_equal [1, 2, nil, nil, nil, nil], books.map(&:ranked_position)
    end

    # Duplicate book records are expected in this catalogue, so equal title and
    # year is a real tie. The rows are inserted with explicit ids, highest first,
    # so an unordered scan reaches the high id before the low one and only an id
    # tie-breaker puts them in id order.
    def write_twins(year:)
      high, low = [2_000_000_002, 2_000_000_001].map do |id|
        book = ::Books::Book.create!(id: id, title: "Twin", first_published_year: year)
        ::Books::BookAuthor.create!(book: book, author: @author, role: :author)
        book
      end
      assert_equal [high.id, low.id], ::Books::Book.where(title: "Twin").pluck(:id), "precondition: heap order is not id order"
      [low, high]
    end

    test "unranked books with the same title and year come back in id order with a configuration" do
      low, high = write_twins(year: 1900)

      books = Books::AuthorBooksQuery.call(author: @author, ranking_configuration: @config).to_a

      assert_equal [low.id, high.id], books.map(&:id)
    end

    test "undated books with the same title come back in id order with a configuration" do
      low, high = write_twins(year: nil)

      books = Books::AuthorBooksQuery.call(author: @author, ranking_configuration: @config).to_a

      assert_equal [low.id, high.id], books.map(&:id)
    end

    test "books with the same title and year come back in id order with no configuration" do
      low, high = write_twins(year: 1900)

      books = Books::AuthorBooksQuery.call(author: @author, ranking_configuration: nil).to_a

      assert_equal [low.id, high.id], books.map(&:id)
    end

    test "leaves out a book the author only edited" do
      authored = write_book("Authored")
      edited = write_book("Edited Anthology", role: :editor)
      rank(edited, 3)

      books = Books::AuthorBooksQuery.call(author: @author, ranking_configuration: @config)

      assert_equal [authored.id], books.map(&:id)
    end

    test "leaves out a provisional book" do
      authored = write_book("Approved")
      write_book("Unapproved", provisional: true)

      books = Books::AuthorBooksQuery.call(author: @author, ranking_configuration: @config)

      assert_equal [authored.id], books.map(&:id)
    end

    test "ranked_only keeps only books ranked on that configuration" do
      ranked = write_book("Ranked")
      write_book("Unranked")
      other_only = write_book("Ranked Elsewhere")
      rank(ranked, 4)
      rank(other_only, 1, config: @other_config)
      rankless = write_book("Rankless")
      RankedItem.new(item: rankless, ranking_configuration: @config, rank: nil, score: 1).save!(validate: false)

      books = Books::AuthorBooksQuery.call(author: @author, ranking_configuration: @config, ranked_only: true)

      assert_equal [ranked.id], books.map(&:id)
      assert_equal [4], books.map(&:ranked_position)
    end

    test "rank is read from the configuration passed, not the primary" do
      book = write_book("Two Ranks")
      rank(book, 1, config: @config)
      rank(book, 9, config: @other_config)

      on_primary = Books::AuthorBooksQuery.call(author: @author, ranking_configuration: @config)
      on_other = Books::AuthorBooksQuery.call(author: @author, ranking_configuration: @other_config)

      assert_equal [1], on_primary.map(&:ranked_position)
      assert_equal [9], on_other.map(&:ranked_position)
    end

    test "with no configuration every ranked_position is nil and ranked_only is empty" do
      late = write_book("Later", year: 1900)
      early = write_book("Earlier", year: 1800)
      rank(late, 1)

      books = Books::AuthorBooksQuery.call(author: @author, ranking_configuration: nil).to_a

      assert_equal [early.id, late.id], books.map(&:id)
      assert_equal [nil, nil], books.map(&:ranked_position)
      assert_empty Books::AuthorBooksQuery.call(author: @author, ranking_configuration: nil, ranked_only: true)
    end

    test "preloads the associations the cards read" do
      write_book("Preloaded")

      book = Books::AuthorBooksQuery.call(author: @author, ranking_configuration: @config).first

      assert book.association(:book_authors).loaded?
      assert book.association(:primary_image).loaded?
    end

    test "count(:all) works on the relation" do
      ranked = write_book("Ranked")
      write_book("Unranked")
      rank(ranked, 1)

      assert_equal 2, Books::AuthorBooksQuery.call(author: @author, ranking_configuration: @config).count(:all)
      assert_equal 1, Books::AuthorBooksQuery.call(author: @author, ranking_configuration: @config, ranked_only: true).count(:all)
      assert_equal 2, Books::AuthorBooksQuery.call(author: @author, ranking_configuration: nil).count(:all)
    end
  end
end
