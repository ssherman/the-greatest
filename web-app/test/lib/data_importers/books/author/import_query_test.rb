# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Books
    module Author
      class ImportQueryTest < ActiveSupport::TestCase
        test "a name alone is valid" do
          assert ImportQuery.new(name: "Leo Tolstoy").valid?
        end

        test "an Open Library key alone is valid: the name comes from Open Library" do
          assert ImportQuery.new(open_library_author_key: "OL26783A").valid?
        end

        test "neither a name nor a key is invalid, and validate! raises" do
          query = ImportQuery.new(name: " ")

          assert_not query.valid?
          error = assert_raises(ArgumentError) { query.validate! }
          assert_match(/Name is required/, error.message)
        end

        test "a non-string name and non-integer years are invalid" do
          assert_not ImportQuery.new(name: 42).valid?
          assert_not ImportQuery.new(name: "Leo Tolstoy", birth_year: "1828").valid?
          assert_not ImportQuery.new(name: "Leo Tolstoy", death_year: 1910.5).valid?
        end

        test "alternate names and work titles drop blanks and duplicates; a blank key is nil" do
          query = ImportQuery.new(name: "Leo Tolstoy", open_library_author_key: "", alternate_names: ["Lev Tolstoy", "", "Lev Tolstoy", nil],
            work_titles: ["War and Peace", " ", "War and Peace"])

          assert_equal [["Lev Tolstoy"], ["War and Peace"]], [query.alternate_names, query.work_titles]
          assert_nil query.open_library_author_key
        end

        test "from_snapshot rebuilds the query a match decision stored and drops unknown keys" do
          original = ImportQuery.new(name: "Leo Tolstoy", open_library_author_key: "OL26783A", birth_year: 1828, death_year: 1910,
            alternate_names: ["Lev Tolstoy"], work_titles: ["War and Peace"])
          snapshot = original.instance_variables.to_h { |ivar| [ivar.to_s.delete("@"), original.instance_variable_get(ivar)] }

          rebuilt = ImportQuery.from_snapshot(snapshot.merge("retired_field" => "x"))

          assert_equal [original.name, original.open_library_author_key, original.birth_year, original.death_year, original.alternate_names, original.work_titles],
            [rebuilt.name, rebuilt.open_library_author_key, rebuilt.birth_year, rebuilt.death_year, rebuilt.alternate_names, rebuilt.work_titles]
        end
      end
    end
  end
end
