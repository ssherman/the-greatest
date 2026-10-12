require "test_helper"

module Books
  class CategorySlugResolverTest < ActiveSupport::TestCase
    test "an active slug resolves to its category" do
      assert_equal categories(:books_france_location), Books::CategorySlugResolver.call("france")
    end

    test "a merged slug resolves to the merge target" do
      target = categories(:books_france_location)
      ::Books::Category.create!(name: "France (country)", slug: "france-country", category_type: :location, deleted: true, merged_into: target)

      assert_equal target, Books::CategorySlugResolver.call("france-country")
    end

    test "a pre-rename slug resolves through history" do
      category = ::Books::Category.create!(name: "Washington DC", category_type: :location)
      old_slug = category.slug
      category.update!(name: "Washington, D.C.")

      assert_equal category, Books::CategorySlugResolver.call(old_slug)
    end

    test "a slug merged into a deleted category resolves to nil" do
      junk = ::Books::Category.create!(name: "Junk", category_type: :location, deleted: true)
      ::Books::Category.create!(name: "Junk Twin", slug: "junk-twin", category_type: :location, deleted: true, merged_into: junk)

      assert_nil Books::CategorySlugResolver.call("junk-twin")
    end

    test "a deleted unmerged slug and an unknown slug resolve to nil" do
      assert_nil Books::CategorySlugResolver.call("retired-genre")
      assert_nil Books::CategorySlugResolver.call("no-such-slug")
    end

    test "a music category's old slug is not resolved" do
      music = ::Music::Category.create!(name: "Prog Rock", category_type: :genre)
      old_slug = music.slug
      music.update!(name: "Progressive Rock")

      assert_nil Books::CategorySlugResolver.call(old_slug)
    end
  end
end
