require "test_helper"

module Services
  class DescriptionColumnBackfillTest < ActiveSupport::TestCase
    test "creates a description row per populated column with the right source" do
      games_games(:tears_of_the_kingdom).update_column(:description, "A sequel across sky islands.")
      games_companies(:capcom).update_column(:description, "A Japanese game developer and publisher.")
      games_series(:resident_evil).update_column(:description, "A survival horror series.")
      music_albums(:animals).update_column(:description, "A concept album loosely based on Animal Farm.")
      music_artists(:roger_waters).update_column(:description, "English songwriter and bassist.")

      Services::DescriptionColumnBackfill.call

      assert_equal "igdb", Description.find_by(describable: games_games(:tears_of_the_kingdom)).source
      assert_equal "igdb", Description.find_by(describable: games_companies(:capcom)).source
      assert_equal "manual", Description.find_by(describable: games_series(:resident_evil)).source
      assert_equal "ai_generated", Description.find_by(describable: music_albums(:animals)).source
      assert_equal "ai_generated", Description.find_by(describable: music_artists(:roger_waters)).source
    end

    test "writes summary kind, en locale, normal rank and no source_name" do
      music_artists(:roger_waters).update_column(:description, "English songwriter and bassist.")

      Services::DescriptionColumnBackfill.call

      row = Description.find_by(describable: music_artists(:roger_waters))
      assert_equal "summary", row.kind
      assert_equal "en", row.locale
      assert_equal "normal", row.rank
      assert_nil row.source_name
      assert_nil row.license
      assert_nil row.retrieved_at
      assert_equal "English songwriter and bassist.", row.content
    end

    test "skips nil, empty and whitespace-only descriptions" do
      music_artists(:roger_waters).update_column(:description, "")
      music_artists(:david_gilmour).update_column(:description, "   ")
      music_albums(:animals).update_column(:description, nil)

      Services::DescriptionColumnBackfill.call

      assert_nil Description.find_by(describable: music_artists(:roger_waters))
      assert_nil Description.find_by(describable: music_artists(:david_gilmour))
      assert_nil Description.find_by(describable: music_albums(:animals))
    end

    test "leaves an existing description row untouched" do
      existing = descriptions(:dark_side_ai)
      music_albums(:dark_side_of_the_moon).update_column(:description, "column text that must not win")

      Services::DescriptionColumnBackfill.call

      existing.reload
      assert_equal "preferred", existing.rank
      assert_not_equal "column text that must not win", existing.content
    end

    test "is idempotent" do
      music_artists(:roger_waters).update_column(:description, "English songwriter and bassist.")
      Services::DescriptionColumnBackfill.call
      after_first = Description.count

      assert_no_difference "Description.count" do
        Services::DescriptionColumnBackfill.call
      end
      assert_equal after_first, Description.count
    end

    test "does not create rows for books" do
      before = Description.where(describable_type: ["Books::Book", "Books::Author"]).count

      Services::DescriptionColumnBackfill.call

      assert_equal before, Description.where(describable_type: ["Books::Book", "Books::Author"]).count
    end

    test "returns a successful result with per-model counts and a total" do
      games_games(:tears_of_the_kingdom).update_column(:description, "A sequel across sky islands.")
      music_artists(:roger_waters).update_column(:description, "English songwriter and bassist.")

      result = Services::DescriptionColumnBackfill.call

      assert result.success?
      assert_empty result.errors
      assert_equal ::Games::Game.where.not(description: [nil, ""]).count,
        result.data[:counts]["Games::Game"]
      assert_equal ::Music::Artist.where.not(description: [nil, ""]).count,
        result.data[:counts]["Music::Artist"]
      assert_equal result.data[:counts].values.sum, result.data[:total]
    end
  end
end
