# frozen_string_literal: true

require "test_helper"

class Admin::Music::Albums::Wizard::ReviewStepComponentTest < ViewComponent::TestCase
  setup do
    @list = lists(:music_albums_list)
    @list.list_items.destroy_all
  end

  test "renders stats cards" do
    render_inline(Admin::Music::Albums::Wizard::ReviewStepComponent.new(
      list: @list,
      items: [],
      total_count: 10,
      valid_count: 5,
      invalid_count: 3,
      missing_count: 2
    ))

    assert_selector "div[id='review_stats_#{@list.id}']"
    assert_text "Total Items"
    assert_text "10"
    assert_text "Valid"
    assert_text "5"
    assert_text "Invalid"
    assert_text "3"
    assert_text "Missing"
    assert_text "2"
  end

  test "renders filter dropdown" do
    render_inline(Admin::Music::Albums::Wizard::ReviewStepComponent.new(
      list: @list,
      items: [],
      total_count: 0,
      valid_count: 0,
      invalid_count: 0,
      missing_count: 0
    ))

    assert_selector "select#status-filter"
    assert_selector "option[value='all']"
    assert_selector "option[value='valid']"
    assert_selector "option[value='invalid']"
    assert_selector "option[value='missing']"
  end

  test "renders empty state when no items" do
    render_inline(Admin::Music::Albums::Wizard::ReviewStepComponent.new(
      list: @list,
      items: [],
      total_count: 0,
      valid_count: 0,
      invalid_count: 0,
      missing_count: 0
    ))

    assert_text "No items to review"
  end

  test "renders item rows" do
    item = @list.list_items.create!(
      position: 1,
      verified: false,
      metadata: {"title" => "Test Album", "artists" => ["Test Artist"]}
    )

    render_inline(Admin::Music::Albums::Wizard::ReviewStepComponent.new(
      list: @list,
      items: [item],
      total_count: 1,
      valid_count: 0,
      invalid_count: 0,
      missing_count: 1
    ))

    assert_selector "tr[id='item_row_#{item.id}']"
    assert_text "Test Album"
    assert_text "Test Artist"
  end

  test "renders valid status badge for verified items" do
    item = @list.list_items.create!(
      position: 1,
      verified: true,
      metadata: {"title" => "Valid Album", "artists" => ["Artist"]}
    )

    render_inline(Admin::Music::Albums::Wizard::ReviewStepComponent.new(
      list: @list,
      items: [item],
      total_count: 1,
      valid_count: 1,
      invalid_count: 0,
      missing_count: 0
    ))

    assert_selector "tr[data-status='valid']"
    assert_selector ".badge-success"
  end

  test "renders invalid status badge for items with ai_match_invalid" do
    item = @list.list_items.create!(
      position: 1,
      verified: false,
      metadata: {"title" => "Invalid Album", "artists" => ["Artist"], "ai_match_invalid" => true}
    )

    render_inline(Admin::Music::Albums::Wizard::ReviewStepComponent.new(
      list: @list,
      items: [item],
      total_count: 1,
      valid_count: 0,
      invalid_count: 1,
      missing_count: 0
    ))

    assert_selector "tr[data-status='invalid']"
    assert_selector ".badge-error"
  end

  test "renders shared modal component" do
    render_inline(Admin::Music::Albums::Wizard::ReviewStepComponent.new(
      list: @list,
      items: [],
      total_count: 0,
      valid_count: 0,
      invalid_count: 0,
      missing_count: 0
    ))

    assert_selector "dialog##{Admin::Music::Albums::Wizard::SharedModalComponent::DIALOG_ID}"
  end

  test "renders opensearch source with score when score is a string" do
    # Regression test: when position is manually edited, opensearch_score can be stored as a string
    # which caused 'undefined method round for an instance of String' error
    item = @list.list_items.create!(
      position: 1,
      verified: true,
      metadata: {
        "title" => "Test Album",
        "artists" => ["Test Artist"],
        "opensearch_match" => true,
        "opensearch_score" => "18.5"  # String instead of float
      }
    )

    render_inline(Admin::Music::Albums::Wizard::ReviewStepComponent.new(
      list: @list,
      items: [item],
      total_count: 1,
      valid_count: 1,
      invalid_count: 0,
      missing_count: 0
    ))

    assert_selector ".badge", text: "OS 18.5"
  end
end
