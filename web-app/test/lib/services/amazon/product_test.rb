# frozen_string_literal: true

require "test_helper"

module Services
  module Amazon
    class ProductTest < ActiveSupport::TestCase
      def product(listings)
        {"offersV2" => {"listings" => listings}}
      end

      def new_listing(amount)
        {"condition" => {"value" => "New"}, "price" => {"money" => {"amount" => amount}}}
      end

      def used_listing(amount)
        {"condition" => {"value" => "Used"}, "price" => {"money" => {"amount" => amount}}}
      end

      test "lowest_price_cents picks the cheapest new listing rather than the first one" do
        assert_equal 1250, Product.lowest_price_cents(product([new_listing(39.99), new_listing(12.50), new_listing(20.00)]))
      end

      test "lowest_price_cents ignores cheaper used listings when a new one exists" do
        assert_equal 3999, Product.lowest_price_cents(product([new_listing(39.99), used_listing(4.50)]))
      end

      test "lowest_price_cents falls back to the cheapest listing when nothing is new" do
        assert_equal 450, Product.lowest_price_cents(product([used_listing(9.99), used_listing(4.50)]))
      end

      test "lowest_price_cents converts dollars to whole cents" do
        assert_equal 1999, Product.lowest_price_cents(product([new_listing(19.99)]))
      end

      test "lowest_price_cents returns nil when the product has no offers at all" do
        assert_nil Product.lowest_price_cents({"asin" => "B001"})
      end

      test "lowest_price_cents returns nil when the listings array is empty" do
        assert_nil Product.lowest_price_cents(product([]))
      end

      test "lowest_price_cents skips listings that carry no price" do
        assert_equal 2500, Product.lowest_price_cents(product([{"condition" => {"value" => "New"}}, new_listing(25.00)]))
      end

      test "lowest_price_cents returns nil when no listing carries a price" do
        assert_nil Product.lowest_price_cents(product([{"condition" => {"value" => "New"}}]))
      end
    end
  end
end
