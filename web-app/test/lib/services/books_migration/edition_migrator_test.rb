require "test_helper"

class Services::BooksMigration::EditionMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    migrator = Services::BooksMigration::EditionMigrator.new
    migrator.stubs(:legacy_each).multiple_yields(*rows.zip)
    migrator.call
  end

  test "creates editions with fresh ids, records the id map, sets book_id, and extracts publisher_name" do
    book = Books::Book.create!(title: "Edition Parent")
    md = {"amazon" => {"ItemInfo" => {"ByLineInfo" => {"Manufacturer" => {"DisplayValue" => "Penguin"}}}}}

    result = run_migrator([
      {"id" => 5001, "book_id" => book.id, "title" => "HC", "publication_year" => 1990,
       "popularity" => 10, "book_binding" => 1, "metadata" => md}
    ])

    assert result[:success], result[:error]
    assert_equal 1, result[:data][:count]
    assert_equal "Books::Edition", result[:data][:model]

    new_id = LegacyIdMap.lookup(model: "Books::Edition", legacy_id: 5001)
    assert_not_nil new_id
    edition = Books::Edition.find(new_id)
    assert_equal book.id, edition.book_id
    assert_equal "HC", edition.title
    assert_equal 1990, edition.publication_year
    assert_equal "hardcover", edition.book_binding
    assert_equal "standard", edition.edition_type
    assert_equal "Penguin", edition.publisher_name
    assert_equal md, edition.metadata
  end

  test "is idempotent: re-running updates in place without duplicating or remapping" do
    book = Books::Book.create!(title: "Idem Edition Parent")
    run_migrator([{"id" => 5002, "book_id" => book.id, "title" => "V1", "book_binding" => 0}])
    first_id = LegacyIdMap.lookup(model: "Books::Edition", legacy_id: 5002)

    assert_no_difference -> { Books::Edition.count } do
      run_migrator([{"id" => 5002, "book_id" => book.id, "title" => "V2", "book_binding" => 0}])
    end
    assert_equal first_id, LegacyIdMap.lookup(model: "Books::Edition", legacy_id: 5002)
    assert_equal "V2", Books::Edition.find(first_id).title
  end

  test "suppresses search indexing during the load" do
    book = Books::Book.create!(title: "Quiet Edition Parent")
    assert_no_difference -> { SearchIndexRequest.count } do
      run_migrator([{"id" => 5003, "book_id" => book.id, "title" => "Q", "book_binding" => nil}])
    end
  end

  test "finalize sets default_edition_id to the most-popular edition" do
    book = Books::Book.create!(title: "Popularity Parent")
    run_migrator([
      {"id" => 5004, "book_id" => book.id, "title" => "Low", "popularity" => 1, "book_binding" => 0},
      {"id" => 5005, "book_id" => book.id, "title" => "High", "popularity" => 99, "book_binding" => 0}
    ])
    high_id = LegacyIdMap.lookup(model: "Books::Edition", legacy_id: 5005)
    assert_equal high_id, book.reload.default_edition_id
  end

  test "a book with no editions keeps default_edition_id nil" do
    editionless = Books::Book.create!(title: "Editionless Parent")
    other = Books::Book.create!(title: "Has Edition")
    run_migrator([{"id" => 5006, "book_id" => other.id, "title" => "E", "book_binding" => 0}])
    assert_nil editionless.reload.default_edition_id
  end

  test "finalize prefers a valued popularity over a nil-popularity edition (NULLS LAST)" do
    book = Books::Book.create!(title: "Nulls Last Parent")
    run_migrator([
      {"id" => 5007, "book_id" => book.id, "title" => "NilPop", "popularity" => nil, "book_binding" => 0},
      {"id" => 5008, "book_id" => book.id, "title" => "ValPop", "popularity" => 5, "book_binding" => 0}
    ])
    valued_id = LegacyIdMap.lookup(model: "Books::Edition", legacy_id: 5008)
    assert_equal valued_id, book.reload.default_edition_id
  end

  test "finalize breaks equal-popularity ties by lowest edition id" do
    book = Books::Book.create!(title: "Tiebreak Parent")
    run_migrator([
      {"id" => 5009, "book_id" => book.id, "title" => "A", "popularity" => 7, "book_binding" => 0},
      {"id" => 5010, "book_id" => book.id, "title" => "B", "popularity" => 7, "book_binding" => 0}
    ])
    id_5009 = LegacyIdMap.lookup(model: "Books::Edition", legacy_id: 5009)
    id_5010 = LegacyIdMap.lookup(model: "Books::Edition", legacy_id: 5010)
    assert_equal [id_5009, id_5010].min, book.reload.default_edition_id
  end
end
