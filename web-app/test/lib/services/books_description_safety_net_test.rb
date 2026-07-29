require "test_helper"

module Services
  class BooksDescriptionSafetyNetTest < ActiveSupport::TestCase
    test "gives a :manual row to a book with a description column and no description row" do
      book = books_books(:of_mice_and_men)
      book.update_column(:description, "Written in the app, never in legacy.")

      result = Services::BooksDescriptionSafetyNet.call

      assert result.success?, result.errors.inspect
      row = Description.find_by(describable: book)
      assert_equal "manual", row.source
      assert_equal "Written in the app, never in legacy.", row.content
      assert_equal "summary", row.kind
      assert_equal "en", row.locale
      assert_equal "normal", row.rank
      assert_nil row.source_name
      assert_nil row.license
      assert_nil row.source_url
    end

    test "gives a :manual row to an author with a description column and no description row" do
      author = books_authors(:king)
      author.update_column(:description, "An in-app author biography.")

      Services::BooksDescriptionSafetyNet.call

      assert_equal "manual", Description.find_by(describable: author).source
    end

    # The whole point of running after the legacy migrators: a record they covered must not
    # get :manual provenance stamped onto legacy-sourced text.
    test "skips a book that already has a description row from another source" do
      book = books_books(:war_and_peace)
      book.update_column(:description, "The legacy raw column, already migrated.")

      assert_no_difference -> { Description.where(describable: book).count } do
        Services::BooksDescriptionSafetyNet.call
      end
      assert_empty Description.where(describable: book, source: :manual)
    end

    test "skips a book whose existing row is for a different kind or locale, only when none exists at all" do
      book = books_books(:of_mice_and_men)
      book.update_column(:description, "In-app text.")
      Description.create!(describable: book, kind: :long, locale: "en",
        source: :ai_generated, content: "A long-kind row.", rank: :normal)

      assert_no_difference -> { Description.where(describable: book).count } do
        Services::BooksDescriptionSafetyNet.call
      end
    end

    test "skips nil, empty and whitespace-only description columns" do
      books_books(:of_mice_and_men).update_column(:description, "")
      books_books(:cannery_row).update_column(:description, "   ")
      books_books(:got).update_column(:description, nil)

      Services::BooksDescriptionSafetyNet.call

      assert_nil Description.find_by(describable: books_books(:of_mice_and_men))
      assert_nil Description.find_by(describable: books_books(:cannery_row))
      assert_nil Description.find_by(describable: books_books(:got))
    end

    test "reports per-model counts and a total" do
      books_books(:of_mice_and_men).update_column(:description, "A book.")
      books_authors(:king).update_column(:description, "An author.")

      result = Services::BooksDescriptionSafetyNet.call

      assert_equal 1, result.data[:counts]["Books::Book"]
      assert_equal 1, result.data[:counts]["Books::Author"]
      assert_equal 2, result.data[:total]
    end

    test "succeeds with a zero total when every record is already covered" do
      result = Services::BooksDescriptionSafetyNet.call

      assert result.success?, result.errors.inspect
      assert_equal 0, result.data[:total]
    end

    test "is idempotent" do
      books_books(:of_mice_and_men).update_column(:description, "A book.")
      Services::BooksDescriptionSafetyNet.call

      second = nil
      assert_no_difference -> { Description.count } do
        second = Services::BooksDescriptionSafetyNet.call
      end
      assert_equal 0, second.data[:total]
    end

    test "does not touch games or music records" do
      games_games(:tears_of_the_kingdom).update_column(:description, "A game.")
      music_albums(:animals).update_column(:description, "An album.")

      Services::BooksDescriptionSafetyNet.call

      assert_nil Description.find_by(describable: games_games(:tears_of_the_kingdom))
      assert_nil Description.find_by(describable: music_albums(:animals))
    end
  end
end
