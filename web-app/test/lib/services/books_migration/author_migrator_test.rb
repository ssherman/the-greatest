require "test_helper"

class Services::BooksMigration::AuthorMigratorTest < ActiveSupport::TestCase
  include SequenceIsolation

  isolate_sequences "books_authors"

  def legacy_rows
    [
      {"id" => 90001, "name" => "Legacy Author One", "family_name" => "One", "alternative_names" => nil},
      {"id" => 90002, "name" => "Legacy Author Two", "family_name" => "Two", "alternative_names" => ["L. Two"]}
    ]
  end

  def run_migrator(rows = legacy_rows)
    migrator = Services::BooksMigration::AuthorMigrator.new
    migrator.stubs(:legacy_each).multiple_yields(*rows.zip)
    migrator.call
  end

  test "creates authors preserving the legacy id, with a generated slug" do
    result = run_migrator
    assert result[:success], result[:error]
    assert_equal 2, result[:data][:count]

    a = ::Books::Author.find(90001)
    assert_equal "Legacy Author One", a.name
    assert_equal "One", a.sort_name
    assert a.slug.present?
    assert_equal ["L. Two"], ::Books::Author.find(90002).alternate_names
  end

  test "suppresses search indexing during the load" do
    assert_no_difference -> { SearchIndexRequest.count } do
      run_migrator
    end
  end

  test "is idempotent: re-running does not duplicate or error" do
    run_migrator
    assert_no_difference -> { ::Books::Author.count } do
      run_migrator
    end
  end

  test "moves the books_authors sequence to the reserved floor after the load" do
    Services::BooksMigration.expects(:bump_sequence_to_floor!).with("books_authors")

    result = run_migrator

    assert result[:success], result[:error]
  end

  test "fails the run when a legacy author id reaches the reserved ceiling" do
    ceiling = Services::BooksMigration::RESERVED_CEILINGS.fetch("books_authors")

    result = run_migrator([{"id" => ceiling, "name" => "Too High", "family_name" => "High", "alternative_names" => nil}])

    refute result[:success]
    assert_includes result[:error], "reserved ceiling"
    refute ::Books::Author.exists?(ceiling)
  end
end
