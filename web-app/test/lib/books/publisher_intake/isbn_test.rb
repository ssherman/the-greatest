# frozen_string_literal: true

require "test_helper"

module Books
  module PublisherIntake
    class IsbnTest < ActiveSupport::TestCase
      test "a valid ISBN-13 is returned as is" do
        assert_equal "9780316564861", Isbn.normalize("9780316564861")
      end

      test "hyphens and spaces are removed" do
        assert_equal "9780802169990", Isbn.normalize("978-0-8021-6999-0")
        assert_equal "9780802169990", Isbn.normalize(" 978 0802169990 ")
      end

      test "an ISBN-10 is converted to ISBN-13" do
        assert_equal "9780802169990", Isbn.normalize("0802169996")
      end

      test "a wrong check digit is nil" do
        assert_nil Isbn.normalize("9780316564860")
      end

      test "blank and nil are nil" do
        assert_nil Isbn.normalize("")
        assert_nil Isbn.normalize(nil)
      end
    end
  end
end
