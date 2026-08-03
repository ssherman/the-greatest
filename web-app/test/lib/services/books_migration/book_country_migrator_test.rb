require "test_helper"

class Services::BooksMigration::BookCountryMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    m = Services::BooksMigration::BookCountryMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  def make_country(legacy_id, name:)
    Books::Country.create!(id: legacy_id, name: name)
  end

  test "creates a join row for a migrated book and country" do
    country = make_country(9101, name: "Peruvian")
    book = Books::Book.create!(title: "Join Row Book")

    result = run_migrator([{"id" => 1, "book_id" => book.id, "country_id" => country.id}])

    assert result[:success], result[:error]
    assert_equal 1, result[:data][:count]
    assert_equal "Books::BookCountry", result[:data][:model]
    assert Books::BookCountry.exists?(book_id: book.id, country_id: country.id)
  end

  test "carries both countries across for a book that has two" do
    first = make_country(9102, name: "Russian")
    second = make_country(9103, name: "American")
    book = Books::Book.create!(title: "Dual Country Book")

    result = run_migrator([
      {"id" => 2, "book_id" => book.id, "country_id" => first.id},
      {"id" => 3, "book_id" => book.id, "country_id" => second.id}
    ])

    assert result[:success], result[:error]
    assert_equal [first, second].map(&:id).sort, book.reload.countries.pluck(:id).sort
  end

  test "is idempotent on the (book, country) key" do
    country = make_country(9104, name: "Chilean")
    book = Books::Book.create!(title: "Idempotent Join Book")
    rows = [{"id" => 4, "book_id" => book.id, "country_id" => country.id}]
    run_migrator(rows)

    assert_no_difference -> { Books::BookCountry.count } do
      result = run_migrator(rows)
      assert result[:success], result[:error]
    end
  end

  test "fails loud on a country id that was never migrated" do
    book = Books::Book.create!(title: "Dangling Country Book")

    result = run_migrator([{"id" => 5, "book_id" => book.id, "country_id" => 424242}])

    assert_not result[:success]
    assert_match "424242", result[:error]
    assert_equal 0, Books::BookCountry.where(book_id: book.id).count
  end

  test "fails loud on a book id that was never migrated" do
    country = make_country(9105, name: "Bolivian")

    result = run_migrator([{"id" => 6, "book_id" => 424242, "country_id" => country.id}])

    assert_not result[:success]
  end

  test "finalize recomputes book_count for a populated country" do
    country = make_country(9106, name: "Ecuadorian")
    first = Books::Book.create!(title: "Count Book 1")
    second = Books::Book.create!(title: "Count Book 2")

    run_migrator([
      {"id" => 7, "book_id" => first.id, "country_id" => country.id},
      {"id" => 8, "book_id" => second.id, "country_id" => country.id}
    ])

    assert_equal 2, country.reload.book_count
  end

  test "finalize zeroes book_count for a country with no links" do
    country = make_country(9107, name: "Paraguayan")
    country.update_column(:book_count, 99)
    other = make_country(9108, name: "Uruguayan")
    book = Books::Book.create!(title: "Unrelated Count Book")

    run_migrator([{"id" => 9, "book_id" => book.id, "country_id" => other.id}])

    assert_equal 0, country.reload.book_count
  end
end
