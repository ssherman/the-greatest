require "test_helper"

class Services::BooksMigration::CountryMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    m = Services::BooksMigration::CountryMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  def legacy_row(overrides = {})
    {
      "id" => 9001,
      "name" => "Peruvian",
      "slug" => "peruvian",
      "description" => "Books of Peruvian origin.",
      "labels" => ["latin_american"],
      "book_count" => 312
    }.merge(overrides)
  end

  test "creates a country preserving the legacy id" do
    result = run_migrator([legacy_row])

    assert result[:success], result[:error]
    assert_equal 1, result[:data][:count]
    assert_equal "Books::Country", result[:data][:model]

    country = Books::Country.find(9001)
    assert_equal "Peruvian", country.name
    assert_equal "Books of Peruvian origin.", country.description
    assert_equal ["latin_american"], country.labels
  end

  test "preserves the legacy slug verbatim rather than regenerating it from the name" do
    result = run_migrator([legacy_row("name" => "United States", "slug" => "american")])

    assert result[:success], result[:error]
    assert_equal "american", Books::Country.find(9001).slug
  end

  test "maps nil labels to an empty array" do
    result = run_migrator([legacy_row("labels" => nil)])

    assert result[:success], result[:error]
    assert_equal [], Books::Country.find(9001).labels
  end

  test "leaves book_count at zero for BookCountryMigrator to recompute" do
    run_migrator([legacy_row])

    assert_equal 0, Books::Country.find(9001).book_count
  end

  test "is idempotent on id" do
    rows = [legacy_row]
    run_migrator(rows)

    assert_no_difference -> { Books::Country.count } do
      result = run_migrator(rows)
      assert result[:success], result[:error]
    end
  end

  test "updates an existing row on re-run rather than duplicating it" do
    run_migrator([legacy_row])
    run_migrator([legacy_row("name" => "Peruvian (revised)")])

    assert_equal "Peruvian (revised)", Books::Country.find(9001).name
  end

  test "resets the primary key sequence so later inserts do not collide" do
    Books::Country.connection.expects(:reset_pk_sequence!).with("books_countries")

    result = run_migrator([legacy_row])

    assert result[:success], result[:error]
  end

  test "reports failure with the legacy id when a row cannot be saved" do
    result = run_migrator([legacy_row("name" => nil)])

    assert_not result[:success]
    assert_match "legacy id=9001", result[:error]
  end
end
