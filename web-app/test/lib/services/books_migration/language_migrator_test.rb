require "test_helper"

class Services::BooksMigration::LanguageMigratorTest < ActiveSupport::TestCase
  include BooksLegacySyncHelper

  def legacy_rows
    [
      {"id" => 10, "name" => "Klingon"},
      {"id" => 11, "name" => "French"}
    ]
  end

  test "creates missing languages, dedupes existing by name, and maps legacy ids" do
    Language.create!(name: "French") # pre-existing new-app language (shared table)

    migrator = Services::BooksMigration::LanguageMigrator.new
    migrator.stubs(:legacy_each).multiple_yields(*legacy_rows.zip)

    assert_difference -> { Language.count }, 1 do # only Klingon is new
      result = migrator.call
      assert result[:success]
      assert_equal 2, result[:data][:count]
    end

    assert Language.exists?(name: "Klingon")
    assert_equal Language.find_by(name: "Klingon").id, LegacyIdMap.lookup(model: "Language", legacy_id: 10)
    assert_equal Language.find_by(name: "French").id, LegacyIdMap.lookup(model: "Language", legacy_id: 11)
  end

  test "is idempotent: a second run creates no duplicate languages" do
    migrator = Services::BooksMigration::LanguageMigrator.new
    migrator.stubs(:legacy_each).multiple_yields(*legacy_rows.zip)
    migrator.call

    migrator2 = Services::BooksMigration::LanguageMigrator.new
    migrator2.stubs(:legacy_each).multiple_yields(*legacy_rows.zip)
    assert_no_difference -> { Language.count } do
      migrator2.call
    end
  end

  test "sync mode skips a legacy language already mapped and adds a new one" do
    renamed = Language.create!(name: "Renamed Here")
    LegacyIdMap.record(model: "Language", legacy_id: 801, new_id: renamed.id)
    migrator = Services::BooksMigration::LanguageMigrator.new(sync: sync_scope)
    migrator.stubs(:legacy_each).multiple_yields([{"id" => 801, "name" => "Legacy Name"}], [{"id" => 802, "name" => "Brand New Tongue"}])

    result = migrator.call

    assert result[:success], result[:error]
    refute Language.exists?(name: "Legacy Name")
    assert_equal renamed.id, LegacyIdMap.lookup(model: "Language", legacy_id: 801)
    assert LegacyIdMap.lookup(model: "Language", legacy_id: 802)
  end
end
