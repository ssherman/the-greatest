require "test_helper"

# == Schema Information
#
# Table name: ranking_archives
#
#  id                              :bigint           not null, primary key
#  captured_at                     :datetime         not null
#  description                     :text
#  hidden                          :boolean          default(FALSE), not null
#  item_ids                        :bigint           default([]), not null, is an Array
#  items_count                     :integer          default(0), not null
#  name                            :string           not null
#  period                          :date
#  positions                       :integer          default([]), not null, is an Array
#  scores                          :decimal(10, 2)   default([]), not null, is an Array
#  slug                            :string           not null
#  type                            :string           not null
#  created_at                      :datetime         not null
#  updated_at                      :datetime         not null
#  legacy_ranking_configuration_id :integer
#  ranking_configuration_id        :bigint
#
# Indexes
#
#  index_ranking_archives_on_config_and_period                (ranking_configuration_id,period) UNIQUE WHERE (period IS NOT NULL)
#  index_ranking_archives_on_legacy_config                    (legacy_ranking_configuration_id) UNIQUE WHERE (legacy_ranking_configuration_id IS NOT NULL)
#  index_ranking_archives_on_ranking_configuration_id         (ranking_configuration_id)
#  index_ranking_archives_on_type_and_hidden_and_captured_at  (type,hidden,captured_at)
#  index_ranking_archives_on_type_and_slug                    (type,slug) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (ranking_configuration_id => ranking_configurations.id) ON DELETE => nullify
#
class RankingArchiveTest < ActiveSupport::TestCase
  def build_archive(**attrs)
    Books::RankingArchive.new({name: "Test Archive", captured_at: Time.current, item_ids: [1, 2], positions: [1, 2], scores: [10, 9]}.merge(attrs))
  end

  test "arrays cannot change after creation" do
    archive = ranking_archives(:books_january_2027)
    before = archive.item_ids.dup
    assert_not archive.update(item_ids: [1], positions: [1], scores: [1], items_count: 1)
    assert_equal before, archive.reload.item_ids
  end

  test "item_ids cannot change on their own" do
    archive = ranking_archives(:books_january_2027)
    before = archive.item_ids.dup
    assert_not archive.update(item_ids: before.reverse.map { |id| id + 1 })
    assert_equal before, archive.reload.item_ids
  end

  test "positions cannot change on their own" do
    archive = ranking_archives(:books_january_2027)
    assert_not archive.update(positions: [2, 1])
    assert_equal [1, 2], archive.reload.positions
  end

  test "scores cannot change on their own" do
    archive = ranking_archives(:books_january_2027)
    assert_not archive.update(scores: [50, 40])
    assert_equal [100, 90], archive.reload.scores
  end

  test "items_count cannot change on its own" do
    archive = ranking_archives(:books_january_2027)
    assert_not archive.update(items_count: 5)
    assert_equal 2, archive.reload.items_count
  end

  test "an in-place array mutation is refused too" do
    archive = ranking_archives(:books_january_2027)
    archive.item_ids << 5
    assert_not archive.save
  end

  test "name, slug, description and hidden can change" do
    assert ranking_archives(:books_january_2027).update(name: "Jan", slug: "jan", description: "x", hidden: true)
  end

  test "an empty archive is invalid" do
    archive = build_archive(item_ids: [], positions: [], scores: [])
    assert_not archive.valid?
    assert archive.errors[:item_ids].any?
  end

  test "arrays must be the same length" do
    archive = build_archive(item_ids: [1, 2], positions: [1], scores: [10, 9])
    assert_not archive.valid?
  end

  test "items_count is set from item_ids on create" do
    archive = build_archive(items_count: 99)
    archive.save!
    assert_equal 2, archive.items_count
  end

  test "slug comes from the name" do
    archive = build_archive(name: "List Dates v1")
    archive.save!
    assert_equal "list-dates-v1", archive.slug
  end

  test "a taken slug gets a numeric suffix" do
    slugs = 3.times.map { build_archive(name: "Spring 2027").tap(&:save!).slug }
    assert_equal %w[spring-2027 spring-2027-2 spring-2027-3], slugs
  end

  test "a name that slugs to nothing falls back to archive" do
    first = build_archive(name: "!!!").tap(&:save!)
    second = build_archive(name: "一月").tap(&:save!)
    assert_equal ["archive", "archive-2"], [first.slug, second.slug]
  end

  test "slug format is enforced on update" do
    archive = ranking_archives(:books_january_2027)
    assert_not archive.update(slug: "My Slug!")
    assert archive.errors[:slug].any?
  end

  test "slug is unique within a type" do
    archive = build_archive(slug: "january-2027")
    assert_not archive.valid?
    assert archive.errors[:slug].any?
  end

  test "period must be the first of a month" do
    assert_not build_archive(period: Date.new(2027, 1, 15)).valid?
    assert build_archive(period: Date.new(2027, 2, 1)).valid?
  end

  test "one monthly archive per configuration and period" do
    existing = ranking_archives(:books_january_2027)
    duplicate = build_archive(slug: "dup", ranking_configuration: existing.ranking_configuration, period: existing.period)
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
  end

  test "summaries leaves the arrays unloaded" do
    row = RankingArchive.summaries.first
    assert_raises(ActiveModel::MissingAttributeError) { row.item_ids }
    assert_equal 2, RankingArchive.summaries.find(ranking_archives(:books_january_2027).id).items_count
  end

  test "visible excludes hidden archives" do
    assert_includes RankingArchive.visible, ranking_archives(:books_january_2027)
    assert_not_includes RankingArchive.visible, ranking_archives(:books_hidden_legacy)
  end

  test "newest_first orders by captured_at then id" do
    ordered = RankingArchive.newest_first.to_a
    assert_operator ordered.index(ranking_archives(:books_january_2027)), :<, ordered.index(ranking_archives(:books_hidden_legacy))
  end

  test "newest_first breaks a captured_at tie by higher id first" do
    at = Time.zone.parse("2028-01-01 00:00:00")
    older = build_archive(name: "Tie A", captured_at: at).tap(&:save!)
    newer = build_archive(name: "Tie B", captured_at: at).tap(&:save!)
    ordered = RankingArchive.newest_first.where(id: [older.id, newer.id]).to_a
    assert_equal [newer, older], ordered
  end

  test "origin" do
    assert_equal :legacy, ranking_archives(:books_hidden_legacy).origin
    assert_equal :monthly, ranking_archives(:books_january_2027).origin
    assert_equal :manual, build_archive.origin
  end

  test "item_type is not defined on the base class" do
    assert_raises(NotImplementedError) { RankingArchive.item_type }
  end

  test "destroying the source configuration keeps the archive" do
    config = Books::RankingConfiguration.create!(name: "Temp Config", global: true)
    archive = Books::RankingArchive.create!(name: "T", captured_at: Time.current, ranking_configuration: config,
      item_ids: [1], positions: [1], scores: [1])
    config.destroy!
    assert_nil archive.reload.ranking_configuration_id
  end
end
