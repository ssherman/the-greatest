require "test_helper"

class Services::BooksMigration::SequenceFloorTest < ActiveSupport::TestCase
  CEILINGS = Services::BooksMigration::RESERVED_CEILINGS

  # Sequence changes are NOT rolled back with the test transaction, so every test
  # positions the sequence itself instead of trusting where an earlier test left it.

  def connection
    ActiveRecord::Base.connection
  end

  def sequence_for(table)
    connection.select_value("SELECT pg_get_serial_sequence(#{connection.quote(table)}, 'id')")
  end

  def set_next_value(table, value)
    connection.execute("SELECT setval(#{connection.quote(sequence_for(table))}, #{value}, false)")
  end

  def peek_next_value(table)
    last_value, is_called = connection.select_rows("SELECT last_value, is_called FROM #{sequence_for(table)}").first
    ActiveModel::Type::Boolean.new.cast(is_called) ? last_value.to_i + 1 : last_value.to_i
  end

  def max_id(table)
    connection.select_value("SELECT COALESCE(MAX(id), 0) FROM #{table}").to_i
  end

  test "moves the sequence up to the ceiling when every row is below it" do
    set_next_value("books_books", 1)
    ceiling = max_id("books_books") + 1_000

    returned = Services::BooksMigration.bump_sequence_to_floor!("books_books", ceiling: ceiling)

    assert_equal ceiling, returned
    assert_equal ceiling, peek_next_value("books_books")
  end

  test "uses max id + 1 when rows already sit above the ceiling" do
    set_next_value("books_books", 1)
    above = max_id("books_books")
    assert_operator above, :>, 1, "fixtures should hold books_books rows"

    returned = Services::BooksMigration.bump_sequence_to_floor!("books_books", ceiling: 1)

    assert_equal above + 1, returned
    assert_equal above + 1, peek_next_value("books_books")
  end

  test "never moves a sequence backward" do
    ceiling = max_id("books_books") + 1_000
    set_next_value("books_books", ceiling + 5_000)

    returned = Services::BooksMigration.bump_sequence_to_floor!("books_books", ceiling: ceiling)

    assert_equal ceiling + 5_000, returned
    assert_equal ceiling + 5_000, peek_next_value("books_books")
  end

  test "is idempotent" do
    set_next_value("books_authors", 1)
    ceiling = max_id("books_authors") + 1_000

    first = Services::BooksMigration.bump_sequence_to_floor!("books_authors", ceiling: ceiling)
    second = Services::BooksMigration.bump_sequence_to_floor!("books_authors", ceiling: ceiling)

    assert_equal [ceiling, ceiling], [first, second]
    assert_equal ceiling, peek_next_value("books_authors")
  end

  test "an empty table gets exactly its configured ceiling" do
    ::SavedSearch.delete_all
    set_next_value("saved_searches", 1)

    returned = Services::BooksMigration.bump_sequence_to_floor!("saved_searches")

    assert_equal CEILINGS.fetch("saved_searches"), returned
    assert_equal CEILINGS.fetch("saved_searches"), ::Books::SavedSearch.create!(
      user: users(:regular_user), criteria: {"genre_match_mode" => "any"}
    ).id
  end

  test "reserve_sequence_floors! moves all four catalog tables to at least their ceilings" do
    Services::BooksMigration::SEQUENCE_FLOOR_TABLES.each { |table| set_next_value(table, 1) }

    result = Services::BooksMigration.reserve_sequence_floors!

    assert_equal %w[books_books books_authors reviews saved_searches], result.keys
    result.each do |table, next_id|
      assert_operator next_id, :>=, CEILINGS.fetch(table), table
      assert_operator next_id, :>, max_id(table), table
      assert_equal next_id, peek_next_value(table), table
    end
  end

  test "reserve_sequence_floors! leaves the relocated tables alone" do
    before = %w[users user_lists lists].index_with { |table| peek_next_value(table) }

    Services::BooksMigration.reserve_sequence_floors!

    assert_equal before, %w[users user_lists lists].index_with { |table| peek_next_value(table) }
  end

  test "raise_if_at_ceiling! accepts an id just below the ceiling" do
    assert_nil Services::BooksMigration.raise_if_at_ceiling!("books_books", CEILINGS.fetch("books_books") - 1)
  end

  test "raise_if_at_ceiling! raises at exactly the ceiling, naming the table and ceiling" do
    error = assert_raises(RuntimeError) do
      Services::BooksMigration.raise_if_at_ceiling!("books_books", CEILINGS.fetch("books_books"))
    end

    assert_includes error.message, "reserved ceiling"
    assert_includes error.message, "books_books"
    assert_includes error.message, "250000"
  end

  test "the catalog ceilings are the values the spec reserved" do
    assert_equal(
      {"books_books" => 250_000, "books_authors" => 120_000, "reviews" => 250_000, "saved_searches" => 20_000},
      CEILINGS.slice("books_books", "books_authors", "reviews", "saved_searches")
    )
  end
end
