require "test_helper"

class Services::BooksMigration::MigratorTest < ActiveSupport::TestCase
  # Minimal test subclass: fails on the row whose legacy id is 2.
  class BoomMigrator < Services::BooksMigration::Migrator
    def model_key
      "Boom"
    end

    def upsert_row(attrs)
      raise "kaboom" if attrs["id"] == 2
    end
  end

  test "a per-row failure names the legacy id and how many succeeded" do
    migrator = BoomMigrator.new
    migrator.stubs(:legacy_each).multiple_yields([{"id" => 1}], [{"id" => 2}], [{"id" => 3}])

    result = migrator.call

    refute result[:success]
    assert_includes result[:error], "legacy id=2"
    assert_equal 1, result[:data][:count]
    assert_equal "Boom", result[:data][:model]
  end

  test "success still returns the processed count" do
    migrator = BoomMigrator.new
    migrator.stubs(:legacy_each).multiple_yields([{"id" => 1}], [{"id" => 3}])

    result = migrator.call

    assert result[:success]
    assert_equal 2, result[:data][:count]
  end
end
