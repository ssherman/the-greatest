require "test_helper"

class Services::BooksMigration::BookMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    migrator = Services::BooksMigration::BookMigrator.new
    migrator.stubs(:legacy_each).multiple_yields(*rows.zip)
    migrator.call
  end

  test "creates books preserving id and remapping original_language_id via the id map" do
    language = Language.create!(name: "Old English")
    LegacyIdMap.record(model: "Language", legacy_id: 700, new_id: language.id)

    result = run_migrator([
      {"id" => 90001, "title" => "Legacy Book One", "sub_title" => "Sub", "first_year_published" => 1954,
       "original_language_id" => 700, "alternate_titles" => ["Alt One"], "alternate_title_1" => "Alt Two"},
      {"id" => 90002, "title" => "Legacy Book Two", "original_language_id" => nil,
       "alternate_titles" => nil, "alternate_title_1" => nil}
    ])

    assert result[:success], result[:error]
    assert_equal 2, result[:data][:count]

    b1 = Books::Book.find(90001)
    assert_equal "Legacy Book One", b1.title
    assert_equal "Sub", b1.subtitle
    assert_equal 1954, b1.first_published_year
    assert_equal language.id, b1.original_language_id
    assert_equal ["Alt One", "Alt Two"], b1.alternate_titles
    assert b1.slug.present?

    b2 = Books::Book.find(90002)
    assert_nil b2.original_language_id
    assert_equal [], b2.alternate_titles
  end

  test "suppresses search indexing during the load" do
    assert_no_difference -> { SearchIndexRequest.count } do
      run_migrator([{"id" => 90003, "title" => "Quiet Book", "original_language_id" => nil}])
    end
  end

  test "is idempotent: re-running does not duplicate or error" do
    rows = [{"id" => 90004, "title" => "Repeat Book", "original_language_id" => nil}]
    run_migrator(rows)
    assert_no_difference -> { Books::Book.count } do
      run_migrator(rows)
    end
  end

  test "resets the books_books sequence above the max migrated id" do
    run_migrator([{"id" => 90005, "title" => "Seq Probe Book", "original_language_id" => nil}])
    fresh = Books::Book.create!(title: "Post Migration Book")
    assert_operator fresh.id, :>, 90005
  end

  test "fails the row (naming the legacy book id) when a non-nil legacy language has no id map" do
    result = run_migrator([
      {"id" => 90010, "title" => "Unmapped Lang Book", "original_language_id" => 999_999}
    ])

    refute result[:success]
    assert_includes result[:error], "legacy id=90010"
    assert_includes result[:error], "999999"
    assert_nil Books::Book.find_by(id: 90010)
  end
end
