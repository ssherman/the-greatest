require "test_helper"

class Services::BooksMigration::AuthorTransformerTest < ActiveSupport::TestCase
  test "maps core fields; sort_name from family_name" do
    attrs = Services::BooksMigration::AuthorTransformer.call(
      {"id" => 5, "name" => "J.R.R. Tolkien", "family_name" => "Tolkien",
       "birth_year" => 1892, "death_year" => 1973, "description" => "Author",
       "alternative_names" => ["John Ronald Reuel Tolkien"]}
    )
    assert_equal "J.R.R. Tolkien", attrs[:name]
    assert_equal "Tolkien", attrs[:sort_name]
    assert_equal 1892, attrs[:birth_year]
    assert_equal 1973, attrs[:death_year]
    assert_equal "Author", attrs[:description]
    assert_equal ["John Ronald Reuel Tolkien"], attrs[:alternate_names]
  end

  test "falls back to name for sort_name and coerces nil alternative_names to []" do
    attrs = Services::BooksMigration::AuthorTransformer.call(
      {"id" => 6, "name" => "Homer", "family_name" => nil, "alternative_names" => nil}
    )
    assert_equal "Homer", attrs[:sort_name]
    assert_equal [], attrs[:alternate_names]
  end
end
