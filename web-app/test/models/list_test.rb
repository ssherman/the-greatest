# == Schema Information
#
# Table name: lists
#
#  id                    :bigint           not null, primary key
#  category_specific     :boolean
#  creator_specific      :boolean
#  description           :text
#  estimated_quality     :integer          default(0), not null
#  high_quality_source   :boolean
#  items_json            :jsonb
#  location_specific     :boolean
#  name                  :string           not null
#  num_years_covered     :integer
#  number_of_voters      :integer
#  raw_content           :text
#  simplified_content    :text
#  source                :string
#  source_country_origin :string
#  status                :integer          default("unapproved"), not null
#  type                  :string           not null
#  url                   :string
#  voter_count_estimated :boolean
#  voter_count_unknown   :boolean
#  voter_names_unknown   :boolean
#  wizard_state          :jsonb
#  year_published        :integer
#  yearly_award          :boolean
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  musicbrainz_series_id :string
#  submitted_by_id       :bigint
#
# Indexes
#
#  index_lists_on_submitted_by_id  (submitted_by_id)
#
# Foreign Keys
#
#  fk_rails_...  (submitted_by_id => users.id)
#
require "test_helper"

class ListTest < ActiveSupport::TestCase
  test "should be valid with valid attributes" do
    assert lists(:basic_list).valid?
  end

  test "should require name" do
    list = lists(:basic_list)
    list.name = nil
    assert_not list.valid?
    assert_includes list.errors[:name], "can't be blank"
  end

  test "should require type" do
    list = lists(:basic_list)
    list.type = nil
    assert_not list.valid?
    assert_includes list.errors[:type], "can't be blank"
  end

  test "should require status" do
    list = lists(:basic_list)
    list.status = nil
    assert_not list.valid?
    assert_includes list.errors[:status], "can't be blank"
  end

  test "should accept valid URL format" do
    list = lists(:basic_list)
    list.url = "https://example.com/list"
    assert list.valid?
  end

  test "should reject invalid URL format" do
    list = lists(:basic_list)
    list.url = "not-a-url"
    assert_not list.valid?
    assert_includes list.errors[:url], "is invalid"
  end

  test "should accept blank URL" do
    list = lists(:basic_list)
    list.url = ""
    assert list.valid?
  end

  test "should have correct enum values" do
    assert_equal 0, List.statuses[:unapproved]
    assert_equal 1, List.statuses[:approved]
    assert_equal 2, List.statuses[:rejected]
  end

  test "approved scope should return approved lists" do
    approved_lists = List.approved
    assert_includes approved_lists, lists(:approved_list)
    assert_includes approved_lists, lists(:high_quality_list)
    assert_not_includes approved_lists, lists(:basic_list)
  end

  test "high_quality scope should return high quality lists" do
    high_quality_lists = List.high_quality
    assert_includes high_quality_lists, lists(:high_quality_list)
    assert_includes high_quality_lists, lists(:approved_list)
    assert_not_includes high_quality_lists, lists(:basic_list)
  end

  test "by_year scope should return lists by year" do
    lists_2023 = List.by_year(2023)
    assert_includes lists_2023, lists(:yearly_award_list)
  end

  test "yearly_awards scope should return yearly award lists" do
    award_lists = List.yearly_awards
    assert_includes award_lists, lists(:yearly_award_list)
    assert_not_includes award_lists, lists(:basic_list)
  end

  test "search_by_name scope should find lists with matching name (case-insensitive)" do
    results = List.search_by_name("basic")
    assert_includes results, lists(:basic_list)

    # Case insensitive
    results_upper = List.search_by_name("BASIC")
    assert_includes results_upper, lists(:basic_list)
  end

  test "search_by_name scope should find lists with matching source (case-insensitive)" do
    list = Music::Songs::List.create!(name: "Test List", source: "Rolling Stone Magazine", status: :unapproved)

    results = List.search_by_name("rolling")
    assert_includes results, list

    # Case insensitive
    results_upper = List.search_by_name("ROLLING")
    assert_includes results_upper, list

    list.destroy
  end

  test "search_by_name scope should return all lists when query is blank" do
    assert_equal List.count, List.search_by_name("").count
    assert_equal List.count, List.search_by_name(nil).count
    assert_equal List.count, List.search_by_name("   ").count
  end

  test "search_by_name scope should escape special SQL characters" do
    # Create a list with special characters in the name
    list = Music::Songs::List.create!(name: "100% Best Songs", status: :unapproved)

    # Should find it with exact special char search
    results = List.search_by_name("100%")
    assert_includes results, list

    # % should not act as wildcard
    results = List.search_by_name("%")
    assert results.all? { |l| l.name.include?("%") || l.source&.include?("%") }

    list.destroy
  end

  test "STI should work with domain-specific classes" do
    books_list = lists(:books_list)
    movies_list = lists(:movies_list)
    music_albums_list = lists(:music_albums_list)
    music_songs_list = lists(:music_songs_list)
    games_list = lists(:games_list)

    assert_equal "Books::List", books_list.type
    assert_equal "Movies::List", movies_list.type
    assert_equal "Music::Albums::List", music_albums_list.type
    assert_equal "Music::Songs::List", music_songs_list.type
    assert_equal "Games::List", games_list.type

    assert books_list.is_a?(Books::List)
    assert movies_list.is_a?(Movies::List)
    assert music_albums_list.is_a?(Music::Albums::List)
    assert music_songs_list.is_a?(Music::Songs::List)
    assert games_list.is_a?(Games::List)
  end

  test "destroying list should destroy associated list_items" do
    list = lists(:basic_list)
    item_count = list.list_items.count
    assert item_count > 0

    list.destroy
    assert_equal 0, ListItem.where(list: list).count
  end

  # Test parse_with_ai! method
  test "parse_with_ai! should call ImportService" do
    list = lists(:basic_list)
    Services::Lists::ImportService.expects(:call).with(list).returns({success: true, data: {}})

    result = list.parse_with_ai!

    assert_equal({success: true, data: {}}, result)
  end

  # Test automatic content simplification callback
  test "should automatically simplify content when raw_content is present on save" do
    list = lists(:basic_list)
    raw_content = "<div><script>alert('test')</script><p>Content</p></div>"
    simplified = "<div><p>Content</p></div>"

    Services::Html::SimplifierService.expects(:call).with(raw_content).returns(simplified)

    list.raw_content = raw_content
    list.save!

    assert_equal simplified, list.simplified_content
  end

  # ============================================
  # Wizard Manager Delegation Test
  # ============================================

  test "wizard_manager returns StateManager for list" do
    list = lists(:music_songs_list)
    manager = list.wizard_manager

    assert_instance_of Services::Lists::Wizard::Music::Songs::StateManager, manager
    assert_equal list, manager.list
  end

  test "wizard_manager is memoized" do
    list = lists(:music_songs_list)
    manager1 = list.wizard_manager
    manager2 = list.wizard_manager

    assert_same manager1, manager2
  end
end
