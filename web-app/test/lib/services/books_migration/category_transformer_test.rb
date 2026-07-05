require "test_helper"

class Services::BooksMigration::CategoryTransformerTest < ActiveSupport::TestCase
  T = Services::BooksMigration::CategoryTransformer

  def legacy(overrides = {})
    {
      "name" => "Speculative Fiction",
      "description" => "desc",
      "category_type" => 0,
      "import_source" => 1,
      "deleted" => false,
      "slug" => "metaphysical-visionary-fiction",
      "merged_category_names" => ["Sci-Fi", "SF"]
    }.merge(overrides)
  end

  test "maps core fields straight through" do
    out = T.call(legacy)
    assert_equal "Speculative Fiction", out[:name]
    assert_equal "desc", out[:description]
    assert_equal false, out[:deleted]
    assert_equal "metaphysical-visionary-fiction", out[:slug]
  end

  test "copies category_type and import_source as raw integers (identical enums, no re-encoding)" do
    out = T.call(legacy("category_type" => 2, "import_source" => 3))
    assert_equal 2, out[:category_type]
    assert_equal 3, out[:import_source]
  end

  test "keeps a nil import_source as nil" do
    assert_nil T.call(legacy("import_source" => nil))[:import_source]
  end

  test "maps merged_category_names to alternative_names" do
    assert_equal ["Sci-Fi", "SF"], T.call(legacy)[:alternative_names]
  end

  test "coerces a nil merged_category_names to an empty array" do
    assert_equal [], T.call(legacy("merged_category_names" => nil))[:alternative_names]
  end
end
