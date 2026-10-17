require "test_helper"

module Books
  class CategoryChainsTest < ActiveSupport::TestCase
    setup do
      @europe = ::Books::Category.create!(name: "Europe", category_type: :location)
      @france = categories(:books_france_location)
      @france.update!(parent: @europe)
      @idf = ::Books::Category.create!(name: "Île-de-France", category_type: :location, parent: @france)
      @paris = ::Books::Category.create!(name: "Paris", category_type: :location, parent: @idf)

      @speculative = ::Books::Category.create!(name: "Speculative Fiction", category_type: :genre, parent: categories(:books_fiction_genre))
      @space_opera = ::Books::Category.create!(name: "Space Opera", category_type: :genre, parent: @speculative)
    end

    test "returns each category's ancestors root first" do
      chains = Books::CategoryChains.call([@paris, @france, @europe])
      assert_equal ["Europe", "France", "Île-de-France"], chains[@paris.id]
      assert_equal ["Europe"], chains[@france.id]
      assert_not chains.key?(@europe.id)
    end

    test "works for genres" do
      assert_equal ["Fiction", "Speculative Fiction"], Books::CategoryChains.call([@space_opera])[@space_opera.id]
    end

    test "stops at a soft-deleted ancestor" do
      @france.update_columns(deleted: true)
      assert_equal ["Île-de-France"], Books::CategoryChains.call([@paris])[@paris.id]
    end

    test "one query however many categories, none when nothing has a parent" do
      assert_queries_count(1) { Books::CategoryChains.call([@paris, @idf, @space_opera]) }
      assert_queries_count(0) { Books::CategoryChains.call([@europe]) }
    end

    test "a parent cycle written around the validation terminates" do
      @europe.update_columns(parent_id: @paris.id)
      chain = Books::CategoryChains.call([@paris])[@paris.id]
      assert_operator chain.size, :<=, Books::Category::MAX_DEPTH
    end
  end
end
