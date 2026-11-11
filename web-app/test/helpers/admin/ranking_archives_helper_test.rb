require "test_helper"

class Admin::RankingArchivesHelperTest < ActionView::TestCase
  CACHE_NOTE = "Pages already cached can stay reachable for up to 24 hours."
  PLAIN = "Delete this archive? This cannot be undone. #{CACHE_NOTE}"
  AUTOMATIC = "This is this month's automatic archive. If you delete it, tomorrow's run creates it again. Hide it instead to keep it off the site. #{CACHE_NOTE}"

  # Late on 28 Feb UTC it is already 1 March in Auckland, so a helper that
  # used the local date would pick the wrong month.
  test "the current UTC month's archive gets the automatic-archive warning" do
    travel_to Time.utc(2027, 2, 28, 23, 59) do
      Time.use_zone("Pacific/Auckland") do
        assert_equal AUTOMATIC, archive_delete_confirmation(::Books::RankingArchive.new(period: Date.new(2027, 2, 1)))
      end
    end
  end

  test "another month's archive gets the plain confirmation" do
    travel_to Time.utc(2027, 2, 28, 23, 59) do
      Time.use_zone("Pacific/Auckland") do
        assert_equal PLAIN, archive_delete_confirmation(::Books::RankingArchive.new(period: Date.new(2027, 3, 1)))
      end
    end
  end

  test "an archive with no period gets the plain confirmation" do
    travel_to Time.utc(2027, 2, 28, 23, 59) do
      assert_equal PLAIN, archive_delete_confirmation(::Books::RankingArchive.new(period: nil))
    end
  end

  test "origin is capitalised for display" do
    assert_equal "Legacy", archive_origin_label(::Books::RankingArchive.new(legacy_ranking_configuration_id: 3))
    assert_equal "Manual", archive_origin_label(::Books::RankingArchive.new)
  end
end
