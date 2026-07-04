require "test_helper"

class Services::BooksMigration::BookTransformerTest < ActiveSupport::TestCase
  test "maps core fields and merges alternate titles" do
    attrs = Services::BooksMigration::BookTransformer.call(
      {"id" => 5, "title" => "The Hobbit", "sub_title" => "There and Back Again",
       "description" => "A tale", "first_year_published" => 1937, "sort_title" => "Hobbit, The",
       "alternate_titles" => ["Hobbit", ""], "alternate_title_1" => "The Hobbit or There and Back Again"}
    )
    assert_equal "The Hobbit", attrs[:title]
    assert_equal "There and Back Again", attrs[:subtitle]
    assert_equal "A tale", attrs[:description]
    assert_equal 1937, attrs[:first_published_year]
    assert_equal "Hobbit, The", attrs[:sort_title]
    assert_equal ["Hobbit", "The Hobbit or There and Back Again"], attrs[:alternate_titles]
  end

  test "alternate_titles is [] when legacy has none, and never includes original_language" do
    attrs = Services::BooksMigration::BookTransformer.call(
      {"id" => 6, "title" => "Beowulf", "alternate_titles" => nil, "alternate_title_1" => nil, "original_language_id" => 3}
    )
    assert_equal [], attrs[:alternate_titles]
    refute attrs.key?(:original_language_id)
  end
end
