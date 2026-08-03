require "test_helper"

# == Schema Information
#
# Table name: books_countries
#
#  id          :bigint           not null, primary key
#  book_count  :integer          default(0), not null
#  description :text
#  labels      :string           default([]), not null, is an Array
#  name        :string           not null
#  slug        :string           not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#
# Indexes
#
#  index_books_countries_on_book_count  (book_count)
#  index_books_countries_on_labels      (labels) USING gin
#  index_books_countries_on_slug        (slug) UNIQUE
#
module Books
  class CountryTest < ActiveSupport::TestCase
    test "requires a name" do
      country = Books::Country.new(name: nil)

      assert_not country.valid?
      assert_includes country.errors[:name], "can't be blank"
    end

    test "generates a slug from the name" do
      country = Books::Country.create!(name: "Sri Lankan")

      assert_equal "sri-lankan", country.slug
    end

    test "finds by slug" do
      assert_equal books_countries(:french), Books::Country.find("french")
    end

    test "with_label selects only countries carrying that label" do
      assert_equal [books_countries(:french)], Books::Country.with_label("western").to_a
    end

    test "without_label excludes countries carrying that label but keeps label-less ones" do
      results = Books::Country.without_label("western")

      assert_not_includes results, books_countries(:french)
      assert_includes results, books_countries(:japanese)
      assert_includes results, books_countries(:unknown)
    end

    test "filterable excludes the unknown bucket" do
      results = Books::Country.filterable

      assert_not_includes results, books_countries(:unknown)
      assert_includes results, books_countries(:french)
    end

    test "sorted_by_name orders alphabetically" do
      names = Books::Country.sorted_by_name.pluck(:name)

      assert_equal names.sort, names
    end
  end
end
