require "test_helper"

module Categories
  class SlugHistoryBackfillTest < ActiveSupport::TestCase
    test "renaming a pre-existing category keeps its old slug resolvable" do
      Categories::SlugHistoryBackfill.call
      category = categories(:books_france_location)
      old_slug = category.slug

      category.update!(name: "French Republic")

      refute_equal old_slug, category.slug
      assert_equal category, ::Books::Category.friendly.find(old_slug)
    end

    test "a new category with a fixture's name and type gets a different slug" do
      Categories::SlugHistoryBackfill.call
      existing = categories(:books_france_location)

      created = ::Books::Category.create!(name: existing.name, category_type: existing.category_type)

      refute_equal existing.slug, created.slug
    end

    test "history rows use friendly_id's scope format" do
      Categories::SlugHistoryBackfill.call
      category = categories(:books_france_location)

      row = FriendlyId::Slug.find_by!(sluggable_id: category.id, slug: category.slug)
      assert_equal "Category", row.sluggable_type
      assert_equal "type:Books::Category", row.scope
    end

    test "is idempotent and never touches categories" do
      before = ::Category.order(:id).pluck(:id, :slug, :updated_at)

      first = Categories::SlugHistoryBackfill.call
      assert_operator first, :>, 0
      assert_equal 0, Categories::SlugHistoryBackfill.call
      assert_equal before, ::Category.order(:id).pluck(:id, :slug, :updated_at)
    end
  end
end
