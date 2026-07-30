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

  test "assign_description returns nil for blank content" do
    album = music_albums(:animals)
    [nil, "", "   ", "\t\n"].each do |blank|
      assert_nil album.assign_description(source: :ai_generated, content: blank),
        "expected #{blank.inspect} to be rejected"
    end
    assert_empty album.descriptions
  end

  test "assign_description builds a summary/en row at the given source" do
    album = music_albums(:animals)

    row = album.assign_description(source: :ai_generated, content: "A concept album about pigs.")

    assert_equal "summary", row.kind
    assert_equal "en", row.locale
    assert_equal "ai_generated", row.source
    assert_equal "A concept album about pigs.", row.content
    assert_equal "normal", row.rank
    assert_not_nil row.retrieved_at
    assert row.new_record?
  end

  test "assign_description accepts extra attributes" do
    album = music_albums(:animals)

    row = album.assign_description(
      source: :wikipedia,
      content: "From Wikipedia.",
      source_url: "https://en.wikipedia.org/wiki/Animals",
      license: :cc_by_sa_4
    )

    assert_equal "https://en.wikipedia.org/wiki/Animals", row.source_url
    assert_equal "cc_by_sa_4", row.license
  end

  # dark_side_ai is an existing ai_generated row on this album, at rank: preferred.
  test "assign_description updates the existing row for that source instead of building a second" do
    album = music_albums(:dark_side_of_the_moon)
    existing = descriptions(:dark_side_ai)

    assert_no_difference "Description.count" do
      row = album.assign_description(source: :ai_generated, content: "Rewritten by the AI task.")
      assert_equal existing.id, row.id
      album.save!
    end

    assert_equal "Rewritten by the AI task.", existing.reload.content
  end

  # D5: importers may never write rank.
  test "assign_description never changes rank" do
    album = music_albums(:dark_side_of_the_moon)

    album.assign_description(source: :ai_generated, content: "New text.")
    album.save!

    assert_equal "preferred", descriptions(:dark_side_ai).reload.rank
  end

  test "assign_description leaves a different source's row alone" do
    album = music_albums(:dark_side_of_the_moon)

    album.assign_description(source: :wikipedia, content: "A wikipedia row.")
    album.save!

    assert_equal 2, album.descriptions.reload.size
    assert_equal "preferred", descriptions(:dark_side_ai).reload.rank
  end

  test "assign_description works on an unsaved parent and persists with it" do
    book = Books::Book.new(title: "Assign Description On New Parent")

    book.assign_description(source: :manual, content: "Written before the parent existed.")
    book.save!

    row = book.descriptions.reload.sole
    assert_equal "manual", row.source
    assert_equal "Written before the parent existed.", row.content
  end

  test "assign_description called twice on an unsaved parent updates one row, not two" do
    book = Books::Book.new(title: "Assign Description Twice")

    book.assign_description(source: :manual, content: "first")
    book.assign_description(source: :manual, content: "second")
    book.save!

    assert_equal ["second"], book.descriptions.reload.pluck(:content)
  end

  # The autosave contract: without autosave: true this is a silent no-op.
  test "saving the parent persists a changed existing description" do
    album = music_albums(:animals)
    album.descriptions.create!(kind: :summary, locale: "en", source: :ai_generated, content: "old")
    album.reload

    album.assign_description(source: :ai_generated, content: "new")
    album.save!

    assert_equal "new", album.descriptions.reload.sole.content
  end
end
