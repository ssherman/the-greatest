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

  test "STI should work with domain-specific classes" do
    books_list = lists(:books_list)
    movies_list = lists(:movies_list)
    music_list = lists(:music_list)
    games_list = lists(:games_list)

    assert_equal "Books::List", books_list.type
    assert_equal "Movies::List", movies_list.type
    assert_equal "Music::List", music_list.type
    assert_equal "Games::List", games_list.type

    assert books_list.is_a?(Books::List)
    assert movies_list.is_a?(Movies::List)
    assert music_list.is_a?(Music::List)
    assert games_list.is_a?(Games::List)
  end

  test "destroying list should destroy associated list_items" do
    list = lists(:basic_list)
    item_count = list.list_items.count
    assert item_count > 0

    list.destroy
    assert_equal 0, ListItem.where(list: list).count
  end
end
