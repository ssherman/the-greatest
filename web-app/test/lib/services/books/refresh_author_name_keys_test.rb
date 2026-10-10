require "test_helper"

module Services
  module Books
    class RefreshAuthorNameKeysTest < ActiveSupport::TestCase
      test "fills stale keys, writes only the rows that changed, and reports counts" do
        stale = ::Books::Author.create!(name: "J.D. Salinger", alternate_names: ["Jerome David Salinger"])
        stale.update_columns(name_keys: [])

        result = RefreshAuthorNameKeys.call

        assert result.success?
        assert_equal ["j d salinger", "jerome david salinger"], stale.reload.name_keys
        assert_equal({scanned: ::Books::Author.count, updated: 1}, result.data)
      end

      test "a second run writes nothing" do
        ::Books::Author.create!(name: "J.D. Salinger").update_columns(name_keys: [])
        RefreshAuthorNameKeys.call

        assert_equal 0, RefreshAuthorNameKeys.call.data[:updated]
      end

      test "blank alternate names and characters that need quoting never raise" do
        lewis = ::Books::Author.create!(name: "C. S. Lewis")
        lewis.update_columns(alternate_names: ["", "   ", "C.S. Lewis"], name_keys: [])
        obrien = ::Books::Author.create!(name: "Flann O'Brien")
        obrien.update_columns(alternate_names: ["Myles na gCopaleen", "Brian O\"Nolan"], name_keys: ["stale"])

        RefreshAuthorNameKeys.call

        assert_equal ["c s lewis"], lewis.reload.name_keys
        assert_equal ["flann o'brien", "myles na gcopaleen", "brian o\"nolan"], obrien.reload.name_keys
      end

      test "every stale row is written across batch boundaries" do
        authors = 3.times.map { |i| ::Books::Author.create!(name: "A.B. Writer #{i}") }
        authors.each { |author| author.update_columns(name_keys: []) }

        RefreshAuthorNameKeys.call(batch_size: 2)

        assert_equal [["a b writer 0"], ["a b writer 1"], ["a b writer 2"]], authors.map { |author| author.reload.name_keys }
      end
    end
  end
end
