require "test_helper"

class Services::BooksMigration::LanguageTransformerTest < ActiveSupport::TestCase
  test "maps legacy name; drops legacy-only columns" do
    attrs = Services::BooksMigration::LanguageTransformer.call(
      {"id" => 5, "name" => "French", "description" => "legacy only"}
    )
    assert_equal({name: "French"}, attrs)
  end
end
