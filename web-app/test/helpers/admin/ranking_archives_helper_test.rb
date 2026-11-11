require "test_helper"

class Admin::RankingArchivesHelperTest < ActionView::TestCase
  test "the current month's archive gets the automatic-archive warning" do
    archive = ::Books::RankingArchive.new(period: Time.now.utc.to_date.beginning_of_month)
    assert_includes archive_delete_confirmation(archive), "automatic archive"
  end

  test "an older archive gets the plain confirmation" do
    archive = ::Books::RankingArchive.new(period: Time.now.utc.to_date.beginning_of_month - 1.month)
    assert_equal "Delete this archive? This cannot be undone.", archive_delete_confirmation(archive)
  end

  test "an archive with no period gets the plain confirmation" do
    assert_equal "Delete this archive? This cannot be undone.", archive_delete_confirmation(::Books::RankingArchive.new)
  end

  test "origin is capitalised for display" do
    assert_equal "Legacy", archive_origin_label(::Books::RankingArchive.new(legacy_ranking_configuration_id: 3))
    assert_equal "Manual", archive_origin_label(::Books::RankingArchive.new)
  end
end
