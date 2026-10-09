require "test_helper"

class LegacySyncWatermarkTest < ActiveSupport::TestCase
  test "accepts the three sync keys" do
    LegacySyncWatermark::KEYS.each do |key|
      assert LegacySyncWatermark.new(key: key, value: 1).valid?, key
    end
  end

  test "rejects an unknown key and a missing value" do
    refute LegacySyncWatermark.new(key: "editions", value: 1).valid?
    refute LegacySyncWatermark.new(key: "books", value: nil).valid?
  end

  test "allows one row per key" do
    LegacySyncWatermark.create!(key: "books", value: 1)

    refute LegacySyncWatermark.new(key: "books", value: 2).valid?
  end
end
