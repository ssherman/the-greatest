require "test_helper"

module Collections
  class RegistryTest < ActiveSupport::TestCase
    test "books registers the six curated collections" do
      assert_equal %w[women africa asia latin-america western non-western],
        Collections::Registry.slugs(:books)
    end

    test "find returns the collection for a known slug" do
      collection = Collections::Registry.find(:books, "africa")

      assert_equal "africa", collection.slug
      assert_equal :books, collection.domain
      assert_equal "African", collection.title_prefix
      assert_equal({country_label: "african"}, collection.filter)
    end

    test "find returns the collection for latin-america" do
      collection = Collections::Registry.find(:books, "latin-america")

      assert_equal "latin-america", collection.slug
      assert_equal :books, collection.domain
      assert_equal "Greatest Latin American Books", collection.name
      assert_equal "Latin American", collection.title_prefix
      assert_equal({country_label: "latin_american"}, collection.filter)
    end

    test "find returns nil for an unknown slug" do
      assert_nil Collections::Registry.find(:books, "antarctica")
    end

    test "find returns nil for a domain with no collections" do
      assert_nil Collections::Registry.find(:music, "africa")
      assert_equal [], Collections::Registry.for(:music)
    end

    test "non-western negates the western label rather than naming its own" do
      collection = Collections::Registry.find(:books, "non-western")

      assert_equal({country_label: "western", exclude: true}, collection.filter)
    end

    test "women filters on author gender and reads as a title suffix" do
      collection = Collections::Registry.find(:books, "women")

      assert_nil collection.title_prefix
      assert_equal "Written by Women", collection.title_suffix
      assert_equal({author_gender: :female}, collection.filter)
    end

    test "every collection has a nav name" do
      Collections::Registry.for(:books).each do |collection|
        assert collection.name.present?, "#{collection.slug} has no nav name"
      end
    end
  end
end
