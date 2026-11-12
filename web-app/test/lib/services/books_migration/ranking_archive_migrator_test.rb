require "test_helper"

class Services::BooksMigration::RankingArchiveMigratorTest < ActiveSupport::TestCase
  setup do
    @book_a = books_books(:war_and_peace)
    @book_b = books_books(:crime_and_punishment)
    @book_c = books_books(:got)
  end

  def legacy(id, overrides = {})
    {
      "id" => id,
      "name" => "Legacy #{id}",
      "description" => "About #{id}",
      "archived" => true,
      "global" => true,
      "published_at" => Time.utc(2022, 5, 1, 12),
      "created_at" => Time.utc(2021, 1, 1, 12)
    }.merge(overrides)
  end

  # configs: [config hash]; rows: {legacy_id => [[book_id, position, score], ...]}
  def run_migrator(configs, rows)
    m = Services::BooksMigration::RankingArchiveMigrator.new
    m.stubs(:legacy_configs).returns(configs)
    rows.each { |legacy_id, r| m.stubs(:legacy_ranked_rows).with(legacy_id).returns(r) }
    m.call
  end

  def archive(legacy_id)
    ::Books::RankingArchive.find_by!(legacy_ranking_configuration_id: legacy_id)
  end

  test "creates one archive per legacy configuration" do
    result = run_migrator([legacy(26)], 26 => [[@book_a.id, 1, BigDecimal("12.5")], [@book_b.id, 2, BigDecimal("10.0")]])
    assert result[:success], result[:error]
    assert_equal "Books::RankingArchive", result[:data][:model]
    assert_equal 1, result[:data][:count]
    a = archive(26)
    assert_equal "Books::RankingArchive", a.type
    assert_equal "Legacy 26", a.name
    assert_equal "About 26", a.description
    assert_nil a.ranking_configuration_id
    assert_nil a.period
    assert_equal [@book_a.id, @book_b.id], a.item_ids
    assert_equal [1, 2], a.positions
    assert_equal [BigDecimal("12.5"), BigDecimal("10.0")], a.scores
  end

  test "captured_at is published_at, falling back to created_at" do
    run_migrator([legacy(26), legacy(27, "published_at" => nil)],
      26 => [[@book_a.id, 1, 1]], 27 => [[@book_a.id, 1, 1]])
    assert_equal Time.utc(2022, 5, 1, 12), archive(26).captured_at
    assert_equal Time.utc(2021, 1, 1, 12), archive(27).captured_at
  end

  test "a configuration with no published_at arrives hidden" do
    run_migrator([legacy(26, "published_at" => nil)], 26 => [[@book_a.id, 1, 1]])
    assert archive(26).hidden
  end

  test "a published configuration arrives visible" do
    run_migrator([legacy(26)], 26 => [[@book_a.id, 1, 1]])
    assert_not archive(26).hidden
  end

  test "ties and gaps in position are kept as they are" do
    run_migrator([legacy(26)], 26 => [[@book_a.id, 1, 5], [@book_b.id, 1, 5], [@book_c.id, 3, 4]])
    assert_equal [1, 1, 3], archive(26).positions
  end

  test "a nil score is stored as 0" do
    run_migrator([legacy(26)], 26 => [[@book_a.id, 1, nil]])
    assert_equal [BigDecimal(0)], archive(26).scores
  end

  test "book ids are stored as they are, merged and deleted ones included" do
    merged_id = @book_c.id + 900_001
    deleted_id = @book_c.id + 900_002
    ::RecordRedirect.create!(item_type: "Books::Book", from_id: merged_id, to_id: @book_a.id)
    ::RecordRedirect.create!(item_type: "Books::Book", from_id: deleted_id, to_id: nil)
    result = run_migrator([legacy(26)], 26 => [[@book_a.id, 1, 3], [merged_id, 2, 2], [deleted_id, 3, 1]])
    assert result[:success], result[:error]
    assert_equal [@book_a.id, merged_id, deleted_id], archive(26).item_ids
    assert_equal({live: 1, redirected: 1, deleted: 1, unknown: 0}, result[:data][:books])
  end

  test "an id that is neither a book nor a redirect aborts before anything is written" do
    ghost = @book_c.id + 900_003
    before = ::Books::RankingArchive.count
    result = run_migrator([legacy(26), legacy(27)],
      26 => [[@book_a.id, 1, 1]], 27 => [[@book_b.id, 1, 1], [ghost, 2, 1]])
    assert_equal false, result[:success]
    assert_equal [ghost], result[:data][:unknown_ids]
    assert_equal 1, result[:data][:books][:unknown]
    assert_equal before, ::Books::RankingArchive.count
  end

  test "a second run creates and changes nothing" do
    rows = {26 => [[@book_a.id, 1, 1]]}
    run_migrator([legacy(26)], rows)
    stamp = archive(26).updated_at
    travel 1.hour do
      result = run_migrator([legacy(26)], rows)
      assert result[:success], result[:error]
      assert_equal 0, result[:data][:count]
      assert_equal 1, result[:data][:skipped_existing]
    end
    assert_equal stamp, archive(26).reload.updated_at
  end

  test "a configuration with no positioned rows is skipped and reported" do
    before = ::Books::RankingArchive.count
    result = run_migrator([legacy(26)], 26 => [])
    assert result[:success], result[:error]
    assert_equal [26], result[:data][:skipped_empty]
    assert_equal 0, result[:data][:count]
    assert_equal before, ::Books::RankingArchive.count
  end

  test "two legacy configurations with the same name get different slugs" do
    run_migrator([legacy(26, "name" => "Same"), legacy(27, "name" => "Same")],
      26 => [[@book_a.id, 1, 1]], 27 => [[@book_a.id, 1, 1]])
    assert_equal ["same", "same-2"], [archive(26).slug, archive(27).slug]
  end

  test "a configuration that already has an archive is counted as existing" do
    result = run_migrator([legacy(33)], 33 => [[@book_a.id, 1, 1]])
    assert_equal 1, result[:data][:skipped_existing]
    assert_equal 0, result[:data][:count]
  end

  test "writes no ranked_lists, penalties or legacy id maps" do
    counts = -> { [RankedList.count, Penalty.count, PenaltyApplication.count, LegacyIdMap.count] }
    before = counts.call
    run_migrator([legacy(26)], 26 => [[@book_a.id, 1, 1]])
    assert_equal before, counts.call
  end
end
