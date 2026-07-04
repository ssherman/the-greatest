require "test_helper"

class Services::BooksMigration::AuthorMigratorTest < ActiveSupport::TestCase
  def legacy_rows
    [
      {"id" => 90001, "name" => "Legacy Author One", "family_name" => "One", "alternative_names" => nil},
      {"id" => 90002, "name" => "Legacy Author Two", "family_name" => "Two", "alternative_names" => ["L. Two"]}
    ]
  end

  def run_migrator
    migrator = Services::BooksMigration::AuthorMigrator.new
    migrator.stubs(:legacy_each).multiple_yields(*legacy_rows.zip)
    migrator.call
  end

  test "creates authors preserving the legacy id, with a generated slug" do
    result = run_migrator
    assert result[:success], result[:error]
    assert_equal 2, result[:data][:count]

    a = Books::Author.find(90001)
    assert_equal "Legacy Author One", a.name
    assert_equal "One", a.sort_name
    assert a.slug.present?
    assert_equal ["L. Two"], Books::Author.find(90002).alternate_names
  end

  test "suppresses search indexing during the load" do
    assert_no_difference -> { SearchIndexRequest.count } do
      run_migrator
    end
  end

  test "is idempotent: re-running does not duplicate or error" do
    run_migrator
    assert_no_difference -> { Books::Author.count } do
      run_migrator
    end
  end

  test "resets the books_authors sequence above the max id" do
    run_migrator
    fresh = Books::Author.create!(name: "Sequence Probe")
    assert_operator fresh.id, :>, 90002
  end
end
