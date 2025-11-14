require "test_helper"

class Admin::Music::ListsHelperTest < ActionView::TestCase
  test "count_items_json returns 0 for nil" do
    assert_equal 0, count_items_json(nil)
  end

  test "count_items_json returns 0 for empty hash" do
    assert_equal 0, count_items_json({})
  end

  test "count_items_json returns 0 for empty array" do
    assert_equal 0, count_items_json([])
  end

  test "count_items_json returns 0 for hash with no arrays" do
    assert_equal 0, count_items_json({"foo" => "bar", "baz" => 123})
  end

  test "count_items_json counts items in hash format with albums key" do
    items_json = {
      "albums" => [
        {"rank" => 1, "title" => "Album 1"},
        {"rank" => 2, "title" => "Album 2"},
        {"rank" => 3, "title" => "Album 3"}
      ]
    }
    assert_equal 3, count_items_json(items_json)
  end

  test "count_items_json counts items in hash format with songs key" do
    items_json = {
      "songs" => [
        {"rank" => 1, "title" => "Song 1"},
        {"rank" => 2, "title" => "Song 2"}
      ]
    }
    assert_equal 2, count_items_json(items_json)
  end

  test "count_items_json finds first array value in hash with multiple keys" do
    items_json = {
      "metadata" => {"source" => "test"},
      "albums" => [
        {"rank" => 1, "title" => "Album 1"},
        {"rank" => 2, "title" => "Album 2"},
        {"rank" => 3, "title" => "Album 3"},
        {"rank" => 4, "title" => "Album 4"}
      ],
      "extra" => "data"
    }
    assert_equal 4, count_items_json(items_json)
  end

  test "count_items_json counts items in array format" do
    items_json = [
      {"rank" => 1, "title" => "Album 1"},
      {"rank" => 2, "title" => "Album 2"}
    ]
    assert_equal 2, count_items_json(items_json)
  end

  test "count_items_json handles large counts" do
    items_json = {"albums" => Array.new(1000) { |i| {"rank" => i + 1} }}
    assert_equal 1000, count_items_json(items_json)
  end

  test "count_items_json returns 0 for unexpected types" do
    assert_equal 0, count_items_json(123)
    assert_equal 0, count_items_json(true)
  end

  test "count_items_json parses JSON strings" do
    json_string = '{"albums": [{"rank": 1}, {"rank": 2}, {"rank": 3}]}'
    assert_equal 3, count_items_json(json_string)
  end

  test "count_items_json returns 0 for invalid JSON strings" do
    invalid_json = '{"albums": [invalid'
    assert_equal 0, count_items_json(invalid_json)
  end

  test "items_json_to_string returns nil for nil" do
    assert_nil items_json_to_string(nil)
  end

  test "items_json_to_string returns nil for empty hash" do
    assert_nil items_json_to_string({})
  end

  test "items_json_to_string returns nil for empty array" do
    assert_nil items_json_to_string([])
  end

  test "items_json_to_string converts hash to pretty JSON" do
    items_json = {"albums" => [{"rank" => 1, "title" => "Album 1"}]}
    result = items_json_to_string(items_json)

    assert result.is_a?(String)
    assert_includes result, "albums"
    assert_includes result, "Album 1"
  end

  test "items_json_to_string converts array to pretty JSON" do
    items_json = [{"rank" => 1, "title" => "Album 1"}]
    result = items_json_to_string(items_json)

    assert result.is_a?(String)
    assert_includes result, "Album 1"
  end

  test "items_json_to_string returns string as-is" do
    json_string = '{"albums": [{"rank": 1}]}'
    assert_equal json_string, items_json_to_string(json_string)
  end
end
