require "test_helper"

module DataImporters
  module Sources
    class IdentifiersTest < ActiveSupport::TestCase
      test "returns one candidate per matching identifier, in lookup order, with the identifier as evidence" do
        source = Identifiers.new(
          model_class: ::Books::Book,
          lookups: [[:books_work_openlibrary_id, "OL262758W"], [:books_work_isbn13, "9780140447934"]]
        )

        candidates = source.call

        assert_equal [books_books(:crime_and_punishment), books_books(:war_and_peace)], candidates.map(&:record)
        assert_equal [[:identifier]] * 2, candidates.map(&:sources)
        assert_equal({matched_identifier: {type: "books_work_openlibrary_id", value: "OL262758W"}}, candidates.first.evidence)
        assert_not candidates.first.decisive?, "decisiveness is the finder's call, after corroboration"
      end

      test "returns nothing for values nobody holds" do
        source = Identifiers.new(model_class: ::Books::Book, lookups: [[:books_work_isbn13, "0000000000000"]])

        assert_equal [], source.call
      end

      test "only looks inside the given model class" do
        source = Identifiers.new(model_class: ::Music::Album, lookups: [[:books_work_isbn13, "9780140447934"]])

        assert_equal [], source.call
      end

      test "returns every record sharing a value, so a collision is visible" do
        other = books_books(:crime_and_punishment)
        other.identifiers.create!(identifier_type: :books_work_isbn13, value: "9780140447934")
        source = Identifiers.new(model_class: ::Books::Book, lookups: [[:books_work_isbn13, "9780140447934"]])

        records = source.call.map(&:record)

        assert_equal 2, records.size
        assert_includes records, books_books(:war_and_peace)
        assert_includes records, other
      end

      test "name is :identifier" do
        assert_equal :identifier, Identifiers.new(model_class: ::Books::Book, lookups: []).name
      end
    end
  end
end
