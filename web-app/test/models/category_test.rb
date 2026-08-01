# == Schema Information
#
# Table name: categories
#
#  id                :bigint           not null, primary key
#  alternative_names :string           default([]), is an Array
#  category_type     :integer          default(0)
#  deleted           :boolean          default(FALSE)
#  description       :text
#  import_source     :integer
#  item_count        :integer          default(0)
#  name              :string           not null
#  slug              :string
#  type              :string           not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  parent_id         :bigint
#
# Indexes
#
#  index_categories_on_category_type  (category_type)
#  index_categories_on_deleted        (deleted)
#  index_categories_on_name           (name)
#  index_categories_on_parent_id      (parent_id)
#  index_categories_on_slug           (slug)
#  index_categories_on_type           (type)
#  index_categories_on_type_and_slug  (type,slug)
#
# Foreign Keys
#
#  fk_rails_...  (parent_id => categories.id)
#
require "test_helper"

class CategoryTest < ActiveSupport::TestCase
  def setup
    @music_rock = categories(:music_rock_genre)
    @music_progressive = categories(:music_progressive_rock_genre)
    @music_uk = categories(:music_uk_location)
    @movies_horror = categories(:movies_horror_genre)
  end

  test "should be valid with valid attributes" do
    category = Music::Category.new(
      name: "Jazz",
      category_type: "genre",
      import_source: "musicbrainz"
    )
    assert category.valid?
  end

  test "should require name" do
    category = Music::Category.new(category_type: "genre")
    assert_not category.valid?
    assert_includes category.errors[:name], "can't be blank"
  end

  test "should require type" do
    category = Category.new(name: "Test")
    assert_not category.valid?
    assert_includes category.errors[:type], "can't be blank"
  end

  test "should have correct enum values for category_type" do
    assert_equal 0, @music_rock.category_type_before_type_cast
    assert_equal "genre", @music_rock.category_type

    assert_equal 1, @music_uk.category_type_before_type_cast
    assert_equal "location", @music_uk.category_type
  end

  test "should have correct enum values for import_source" do
    assert_equal 4, @music_rock.import_source_before_type_cast
    assert_equal "musicbrainz", @music_rock.import_source

    assert_equal 0, @movies_horror.import_source_before_type_cast
    assert_equal "amazon", @movies_horror.import_source
  end

  test "should handle alternative_names as array" do
    assert_equal ["Prog Rock"], @music_progressive.alternative_names
    assert_equal ["UK", "Britain"], @music_uk.alternative_names
  end

  test "should support hierarchical relationships" do
    assert_equal @music_rock, @music_progressive.parent
    assert_includes @music_rock.child_categories, @music_progressive
  end

  test "active scope should exclude deleted categories" do
    active_categories = Category.active
    assert_includes active_categories, @music_rock
    assert_not_includes active_categories, categories(:music_deleted_genre)
  end

  test "soft_deleted scope should include only deleted categories" do
    deleted_categories = Category.soft_deleted
    assert_includes deleted_categories, categories(:music_deleted_genre)
    assert_not_includes deleted_categories, @music_rock
  end

  test "sorted_by_name scope should sort alphabetically" do
    categories = Category.sorted_by_name.limit(3)
    names = categories.map(&:name)
    assert_equal names.sort, names
  end

  test "search scope should find categories by partial name match" do
    results = Category.search("Rock")
    assert_includes results, @music_rock
    assert_includes results, @music_progressive

    # Should also work with partial matches
    results = Category.search("Progressive")
    assert_includes results, @music_progressive
    assert_not_includes results, @music_rock
  end

  test "search_by_name scope should find categories by partial name" do
    results = Category.search_by_name("Progressive")
    assert_includes results, @music_progressive
  end

  test "by_name scope should find exact name matches case insensitive" do
    results = Category.by_name("ROCK")
    assert_includes results, @music_rock
  end

  test "by_alternative_name scope should find by alternative names" do
    results = Category.by_alternative_name("UK")
    assert_includes results, @music_uk

    results = Category.by_alternative_name("Prog Rock")
    assert_includes results, @music_progressive
  end

  test "should generate friendly_id slug from name" do
    category = Music::Category.create!(
      name: "Heavy Metal",
      category_type: "genre"
    )
    assert_equal "heavy-metal", category.slug
  end

  test "should allow same slug across different STI types" do
    music_horror = Music::Category.create!(
      name: "Horror",
      category_type: "genre"
    )

    # Should not conflict with movies_horror_genre fixture
    assert_equal "horror", music_horror.slug
    assert_equal "horror", @movies_horror.slug
  end

  test "to_param should return slug" do
    assert_equal @music_rock.slug, @music_rock.to_param
  end

  test "should_generate_new_friendly_id should return true when name changes" do
    @music_rock.name = "Rock Music"
    assert @music_rock.should_generate_new_friendly_id?
  end

  test "should_generate_new_friendly_id should return true when slug is blank" do
    @music_rock.slug = nil
    assert @music_rock.should_generate_new_friendly_id?
  end
end
