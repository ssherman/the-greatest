# frozen_string_literal: true

require "test_helper"

module Books
  class IsbnTest < ActiveSupport::TestCase
    test "an ISBN-10 also yields its ISBN-13" do
      assert_equal ["9780441013593", "0441013597"], pair(Isbn.normalize("0441013597"))
    end

    test "a 978 ISBN-13 also yields its ISBN-10" do
      assert_equal ["9780140447934", "0140447938"], pair(Isbn.normalize("9780140447934"))
    end

    test "a 979 ISBN-13 has no ISBN-10" do
      assert_equal ["9791032305690", nil], pair(Isbn.normalize("9791032305690"))
    end

    test "the Goodreads spreadsheet wrapper, hyphens and spaces are ignored" do
      assert_equal "9780441013593", Isbn.normalize('="9780441013593"').isbn13
      assert_equal "9780441013593", Isbn.normalize("978-0-441 01359-3").isbn13
    end

    test "an ISBN-10 check digit of X is accepted in either case" do
      assert_equal "080442957X", Isbn.normalize("080442957x").isbn10
    end

    test "a failed checksum is dropped" do
      assert_nil Isbn.normalize("0441013598")
      assert_nil Isbn.normalize("9780441013594")
    end

    test "blank, wrapped-blank and non-ISBN values are dropped" do
      [nil, "", '=""', "B00ABC1234", "12345", "ISBN 0441013597"].each do |raw|
        assert_nil Isbn.normalize(raw), raw.inspect
      end
    end

    private

    def pair(normalized)
      [normalized.isbn13, normalized.isbn10]
    end
  end
end
