require "test_helper"

class LegacyIdMapTest < ActiveSupport::TestCase
  test "record creates a mapping and returns new_id" do
    assert_equal 42, LegacyIdMap.record(model: "Language", legacy_id: 7, new_id: 42)
    assert_equal 42, LegacyIdMap.lookup(model: "Language", legacy_id: 7)
  end

  test "record is idempotent and updates new_id on the same key" do
    LegacyIdMap.record(model: "Language", legacy_id: 7, new_id: 42)
    original_created_at = LegacyIdMap.where(model: "Language", legacy_id: 7).pick(:created_at)

    LegacyIdMap.record(model: "Language", legacy_id: 7, new_id: 99)

    assert_equal 1, LegacyIdMap.where(model: "Language", legacy_id: 7).count
    assert_equal 99, LegacyIdMap.lookup(model: "Language", legacy_id: 7)
    assert_equal original_created_at, LegacyIdMap.where(model: "Language", legacy_id: 7).pick(:created_at)
  end

  test "lookup returns nil for an unknown key" do
    assert_nil LegacyIdMap.lookup(model: "Language", legacy_id: 123)
  end
end
