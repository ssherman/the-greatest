require "test_helper"

# == Schema Information
#
# Table name: languages
#
#  id         :bigint           not null, primary key
#  iso_639_1  :string(2)
#  iso_639_3  :string(3)
#  name       :string           not null
#  slug       :string           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
# Indexes
#
#  index_languages_on_iso_639_3  (iso_639_3) UNIQUE
#  index_languages_on_name       (name)
#  index_languages_on_slug       (slug) UNIQUE
#
class LanguageTest < ActiveSupport::TestCase
  test "is valid with a name" do
    assert_predicate Language.new(name: "Klingon"), :valid?
  end

  test "requires a name" do
    language = Language.new
    assert_not language.valid?
    assert_includes language.errors[:name], "can't be blank"
  end

  test "generates a slug from the name" do
    language = Language.create!(name: "Ancient Greek")
    assert_equal "ancient-greek", language.slug
  end

  test "iso_639_3 is unique" do
    dup = Language.new(name: "Latin II", iso_639_3: "lat")
    assert_not dup.valid?
    assert_includes dup.errors[:iso_639_3], "has already been taken"
  end
end
