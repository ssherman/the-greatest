# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class AuthorKindTest < ActiveSupport::TestCase
        test "Unknown, Anonymous and Various are placeholders" do
          ["Unknown", "Anonymous", "Various", "Various Authors"].each do |name|
            assert_equal :placeholder, AuthorKind.kind(::Books::Author.new(name: name))
          end
        end

        test "a country name is a place author with that nationality" do
          chinese = ::Books::Country.find_or_create_by!(name: "Chinese")
          author = ::Books::Author.new(name: "China", birth_year: 1972)
          assert_equal :place, AuthorKind.kind(author)
          assert_equal chinese, AuthorKind.place_country(author)
        end

        test "a person is a person" do
          assert_equal :person, AuthorKind.kind(::Books::Author.new(name: "Ernest Hemingway"))
          assert_nil AuthorKind.place_country(::Books::Author.new(name: "Ernest Hemingway"))
        end
      end
    end
  end
end
