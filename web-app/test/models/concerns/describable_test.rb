require "test_helper"
require "active_record/testing/query_assertions"

class DescribableTest < ActiveSupport::TestCase
  include ActiveRecord::Assertions::QueryAssertions

  test "every content model is describable" do
    [Books::Book, Books::Author, Books::Series,
      Music::Album, Music::Artist, Music::Song,
      Games::Game, Games::Company, Games::Series,
      Movies::Movie, Movies::Person].each do |model|
      assert model.include?(Describable), "#{model} should include Describable"
      assert model.reflect_on_association(:descriptions).present?,
        "#{model} should have a descriptions association"
    end
  end

  test "primary_description resolves the preferred row" do
    assert_equal descriptions(:crime_preferred),
      books_books(:crime_and_punishment).primary_description
  end

  test "primary_description falls back to source priority" do
    assert_equal descriptions(:war_and_peace_ai),
      books_books(:war_and_peace).primary_description
  end

  test "primary_description passes kind and locale through" do
    book = books_books(:war_and_peace)
    assert_equal descriptions(:war_and_peace_long), book.primary_description(kind: :long)
    assert_equal descriptions(:war_and_peace_fr), book.primary_description(locale: "fr")
  end

  test "primary_description returns nil when nothing qualifies" do
    assert_nil books_books(:combo_steinbeck).primary_description
    assert_nil books_books(:got).primary_description
  end

  test "primary_description works across domains" do
    assert_equal descriptions(:dark_side_ai),
      music_albums(:dark_side_of_the_moon).primary_description
    assert_equal descriptions(:botw_igdb),
      games_games(:breath_of_the_wild).primary_description
  end

  test "primary_description issues no query when descriptions are preloaded" do
    books = Books::Book.where(id: books_books(:war_and_peace).id).includes(:descriptions).to_a
    assert_queries_count(0) { books.first.primary_description }
  end

  test "descriptions are destroyed with their describable" do
    book = Books::Book.create!(title: "Describable Destroy Fixture")
    book.descriptions.create!(kind: :summary, locale: "en", source: :manual, content: "temp")

    assert_difference "Description.count", -1 do
      book.destroy
    end
  end
end
