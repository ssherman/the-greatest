# frozen_string_literal: true

require "test_helper"

class Admin::Music::Songs::Wizard::ReviewStepComponentTest < ViewComponent::TestCase
  setup do
    @list = lists(:music_songs_list)
    @list.list_items.unverified.destroy_all

    @song = music_songs(:time)
    @artist = music_artists(:pink_floyd)

    @valid_item = @list.list_items.create!(
      listable: @song,
      listable_type: "Music::Song",
      verified: true,
      position: 1,
      metadata: {
        "title" => "Time",
        "artists" => ["Pink Floyd"],
        "song_id" => @song.id,
        "song_name" => "Time",
        "opensearch_match" => true,
        "opensearch_score" => 18.5
      }
    )

    @invalid_item = @list.list_items.create!(
      listable_type: "Music::Song",
      verified: false,
      position: 2,
      metadata: {
        "title" => "Imagine",
        "artists" => ["John Lennon"],
        "mb_recording_id" => "a1b2c3d4",
        "mb_recording_name" => "Imagine (Live)",
        "mb_artist_names" => ["John Lennon"],
        "musicbrainz_match" => true,
        "ai_match_invalid" => true
      }
    )

    @missing_item = @list.list_items.create!(
      listable_type: "Music::Song",
      verified: false,
      position: 3,
      metadata: {"title" => "Obscure Song", "artists" => ["Unknown Artist"]}
    )

    @items = @list.list_items.ordered.includes(listable: :artists)
    @total_count = 3
    @valid_count = 1
    @invalid_count = 1
    @missing_count = 1
  end

  test "renders stats cards with correct counts" do
    render_inline(Admin::Music::Songs::Wizard::ReviewStepComponent.new(
      list: @list,
      items: @items,
      total_count: @total_count,
      valid_count: @valid_count,
      invalid_count: @invalid_count,
      missing_count: @missing_count
    ))

    assert_selector ".stat-value", text: "3"
    assert_selector ".stat-value", text: "1", count: 3
  end

  test "renders stats cards with correct percentages" do
    render_inline(Admin::Music::Songs::Wizard::ReviewStepComponent.new(
      list: @list,
      items: @items,
      total_count: @total_count,
      valid_count: @valid_count,
      invalid_count: @invalid_count,
      missing_count: @missing_count
    ))

    assert_selector ".stat-desc", text: "33.3% of total", count: 3
  end

  test "renders filter dropdown with all options" do
    render_inline(Admin::Music::Songs::Wizard::ReviewStepComponent.new(
      list: @list,
      items: @items,
      total_count: @total_count,
      valid_count: @valid_count,
      invalid_count: @invalid_count,
      missing_count: @missing_count
    ))

    assert_selector "select option", text: "Show All"
    assert_selector "select option", text: "Valid Only"
    assert_selector "select option", text: "Invalid Only"
    assert_selector "select option", text: "Missing Only"
  end

  test "renders table with all items" do
    render_inline(Admin::Music::Songs::Wizard::ReviewStepComponent.new(
      list: @list,
      items: @items,
      total_count: @total_count,
      valid_count: @valid_count,
      invalid_count: @invalid_count,
      missing_count: @missing_count
    ))

    assert_selector "table"
    assert_selector "tbody tr", count: 3
  end

  test "renders valid item with success badge" do
    render_inline(Admin::Music::Songs::Wizard::ReviewStepComponent.new(
      list: @list,
      items: @items,
      total_count: @total_count,
      valid_count: @valid_count,
      invalid_count: @invalid_count,
      missing_count: @missing_count
    ))

    assert_selector "tr[data-status='valid'] .badge-success"
  end

  test "renders invalid item with error badge and red background" do
    render_inline(Admin::Music::Songs::Wizard::ReviewStepComponent.new(
      list: @list,
      items: @items,
      total_count: @total_count,
      valid_count: @valid_count,
      invalid_count: @invalid_count,
      missing_count: @missing_count
    ))

    assert_selector "tr[data-status='invalid'] .badge-error"
    assert_selector "tr.bg-error\\/10"
  end

  test "renders missing item with ghost badge and gray background" do
    render_inline(Admin::Music::Songs::Wizard::ReviewStepComponent.new(
      list: @list,
      items: @items,
      total_count: @total_count,
      valid_count: @valid_count,
      invalid_count: @invalid_count,
      missing_count: @missing_count
    ))

    assert_selector "tr[data-status='missing'] .badge-ghost"
    assert_selector "tr.bg-base-200"
  end

  test "renders opensearch source with score" do
    render_inline(Admin::Music::Songs::Wizard::ReviewStepComponent.new(
      list: @list,
      items: @items,
      total_count: @total_count,
      valid_count: @valid_count,
      invalid_count: @invalid_count,
      missing_count: @missing_count
    ))

    assert_selector ".badge", text: "OS 18.5"
  end

  test "renders opensearch source with score when score is a string" do
    # Regression test: when position is manually edited, opensearch_score can be stored as a string
    # which caused 'undefined method round for an instance of String' error
    different_song = music_songs(:money)
    item_with_string_score = @list.list_items.create!(
      listable: different_song,
      listable_type: "Music::Song",
      verified: true,
      position: 10,
      metadata: {
        "title" => "Money",
        "artists" => ["Pink Floyd"],
        "song_id" => different_song.id,
        "song_name" => "Money",
        "opensearch_match" => true,
        "opensearch_score" => "18.5"  # String instead of float
      }
    )

    render_inline(Admin::Music::Songs::Wizard::ReviewStepComponent.new(
      list: @list,
      items: [item_with_string_score],
      total_count: 1,
      valid_count: 1,
      invalid_count: 0,
      missing_count: 0
    ))

    assert_selector ".badge", text: "OS 18.5"
  end

  test "renders musicbrainz source badge" do
    render_inline(Admin::Music::Songs::Wizard::ReviewStepComponent.new(
      list: @list,
      items: @items,
      total_count: @total_count,
      valid_count: @valid_count,
      invalid_count: @invalid_count,
      missing_count: @missing_count
    ))

    assert_selector ".badge", text: "MB"
  end

  test "renders original title and artists" do
    render_inline(Admin::Music::Songs::Wizard::ReviewStepComponent.new(
      list: @list,
      items: @items,
      total_count: @total_count,
      valid_count: @valid_count,
      invalid_count: @invalid_count,
      missing_count: @missing_count
    ))

    assert_text "Time"
    assert_text "Pink Floyd"
    assert_text "Imagine"
    assert_text "John Lennon"
    assert_text "Obscure Song"
    assert_text "Unknown Artist"
  end

  test "renders matched song name for opensearch match" do
    render_inline(Admin::Music::Songs::Wizard::ReviewStepComponent.new(
      list: @list,
      items: @items,
      total_count: @total_count,
      valid_count: @valid_count,
      invalid_count: @invalid_count,
      missing_count: @missing_count
    ))

    assert_text "Time"
  end

  test "renders mb recording name for musicbrainz match" do
    render_inline(Admin::Music::Songs::Wizard::ReviewStepComponent.new(
      list: @list,
      items: @items,
      total_count: @total_count,
      valid_count: @valid_count,
      invalid_count: @invalid_count,
      missing_count: @missing_count
    ))

    assert_text "Imagine (Live)"
  end

  test "renders dash for missing items matched column" do
    render_inline(Admin::Music::Songs::Wizard::ReviewStepComponent.new(
      list: @list,
      items: [@missing_item],
      total_count: 1,
      valid_count: 0,
      invalid_count: 0,
      missing_count: 1
    ))

    assert_selector "tr[data-status='missing'] td", text: "-"
  end

  test "renders row with correct data attributes" do
    render_inline(Admin::Music::Songs::Wizard::ReviewStepComponent.new(
      list: @list,
      items: @items,
      total_count: @total_count,
      valid_count: @valid_count,
      invalid_count: @invalid_count,
      missing_count: @missing_count
    ))

    # Rows have data-status for CSS-based filtering (no JS row targets needed)
    assert_selector "tr[data-status='valid']"
    assert_selector "tr[data-status='invalid']"
    assert_selector "tr[data-status='missing']"
  end

  test "handles empty items list" do
    render_inline(Admin::Music::Songs::Wizard::ReviewStepComponent.new(
      list: @list,
      items: [],
      total_count: 0,
      valid_count: 0,
      invalid_count: 0,
      missing_count: 0
    ))

    assert_text "No items to review"
    assert_no_selector "table"
  end

  test "uses review-filter stimulus controller" do
    render_inline(Admin::Music::Songs::Wizard::ReviewStepComponent.new(
      list: @list,
      items: @items,
      total_count: @total_count,
      valid_count: @valid_count,
      invalid_count: @invalid_count,
      missing_count: @missing_count
    ))

    assert_selector "[data-controller='review-filter']"
  end

  test "renders filter target on select" do
    render_inline(Admin::Music::Songs::Wizard::ReviewStepComponent.new(
      list: @list,
      items: @items,
      total_count: @total_count,
      valid_count: @valid_count,
      invalid_count: @invalid_count,
      missing_count: @missing_count
    ))

    assert_selector "select[data-review-filter-target='filter']"
  end

  test "renders count target for visible count" do
    render_inline(Admin::Music::Songs::Wizard::ReviewStepComponent.new(
      list: @list,
      items: @items,
      total_count: @total_count,
      valid_count: @valid_count,
      invalid_count: @invalid_count,
      missing_count: @missing_count
    ))

    assert_selector "[data-review-filter-target='count']"
    assert_text "Showing 3 items"
  end
end
