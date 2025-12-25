# frozen_string_literal: true

require "test_helper"

class Admin::Music::Songs::Wizard::ValidateStepComponentTest < ViewComponent::TestCase
  setup do
    @list = lists(:music_songs_list)
    @list.list_items.unverified.destroy_all

    @list.list_items.create!(
      listable_type: "Music::Song",
      verified: false,
      position: 1,
      metadata: {
        "title" => "Come Together",
        "artists" => ["The Beatles"],
        "song_id" => 123,
        "song_name" => "Come Together",
        "opensearch_match" => true
      }
    )

    @list.list_items.create!(
      listable_type: "Music::Song",
      verified: false,
      position: 2,
      metadata: {
        "title" => "Imagine",
        "artists" => ["John Lennon"],
        "mb_recording_id" => "a1b2c3d4",
        "mb_recording_name" => "Imagine (Live)",
        "mb_artist_names" => ["John Lennon"],
        "musicbrainz_match" => true
      }
    )

    @list.list_items.create!(
      listable_type: "Music::Song",
      verified: false,
      position: 3,
      metadata: {"title" => "Unknown", "artists" => ["Unknown Artist"]}
    )
  end

  def set_validate_state(status:, progress: 0, error: nil, metadata: {})
    @list.update!(wizard_state: {
      "current_step" => 3,
      "steps" => {
        "validate" => {
          "status" => status,
          "progress" => progress,
          "error" => error,
          "metadata" => metadata
        }
      }
    })
  end

  test "renders stats cards" do
    set_validate_state(status: "idle")

    render_inline(Admin::Music::Songs::Wizard::ValidateStepComponent.new(list: @list))

    assert_selector ".stat-title", text: "Total Items"
    assert_selector ".stat-value", text: "3"
    assert_selector ".stat-title", text: "Items to Validate"
    assert_selector ".stat-value", text: "2"
  end

  test "renders progress bar with current progress" do
    set_validate_state(status: "running", progress: 50)

    render_inline(Admin::Music::Songs::Wizard::ValidateStepComponent.new(list: @list))

    assert_selector "progress[value='50'][max='100']"
  end

  test "renders Start Validation button when job idle" do
    set_validate_state(status: "idle")

    render_inline(Admin::Music::Songs::Wizard::ValidateStepComponent.new(list: @list))

    assert_selector "button", text: "Start Validation"
  end

  test "does not render Start Validation button when job running" do
    set_validate_state(status: "running", progress: 25)

    render_inline(Admin::Music::Songs::Wizard::ValidateStepComponent.new(list: @list))

    assert_no_selector "button", text: "Start Validation"
  end

  test "renders error message when job failed" do
    set_validate_state(status: "failed", error: "AI service timeout")

    render_inline(Admin::Music::Songs::Wizard::ValidateStepComponent.new(list: @list))

    assert_selector ".alert-error"
    assert_text "AI service timeout"
  end

  test "uses wizard-step controller when job is running" do
    set_validate_state(status: "running", progress: 25)

    render_inline(Admin::Music::Songs::Wizard::ValidateStepComponent.new(list: @list))

    assert_selector "[data-controller='wizard-step']"
  end

  test "does not use wizard-step controller when job is idle" do
    set_validate_state(status: "idle")

    render_inline(Admin::Music::Songs::Wizard::ValidateStepComponent.new(list: @list))

    assert_no_selector "[data-controller='wizard-step']"
  end

  test "displays results table when completed" do
    set_validate_state(
      status: "completed",
      progress: 100,
      metadata: {"valid_count" => 1, "invalid_count" => 1, "verified_count" => 1, "validated_items" => 2}
    )

    render_inline(Admin::Music::Songs::Wizard::ValidateStepComponent.new(list: @list))

    assert_selector "table"
    assert_text "Validation Results"
  end

  test "shows AI reasoning when completed" do
    set_validate_state(
      status: "completed",
      progress: 100,
      metadata: {
        "valid_count" => 1,
        "invalid_count" => 1,
        "validated_items" => 2,
        "reasoning" => "Item 2 is a live recording"
      }
    )

    render_inline(Admin::Music::Songs::Wizard::ValidateStepComponent.new(list: @list))

    assert_text "AI Analysis"
    assert_text "Item 2 is a live recording"
  end

  test "displays Valid/Invalid badges correctly" do
    # First item - valid and verified (needs enrichment metadata to be included in preview)
    @list.list_items.unverified.ordered.first.update!(verified: true)
    # Second item - invalid (already has enrichment metadata)
    item2 = @list.list_items.ordered.second
    item2.update!(metadata: item2.metadata.merge("ai_match_invalid" => true))

    set_validate_state(
      status: "completed",
      progress: 100,
      metadata: {"validated_items" => 2, "valid_count" => 1, "invalid_count" => 1}
    )

    render_inline(Admin::Music::Songs::Wizard::ValidateStepComponent.new(list: @list))

    assert_selector ".badge-success", text: "Verified"
    assert_selector ".badge-error", text: "Invalid"
  end

  test "shows verified count in stats when completed" do
    set_validate_state(
      status: "completed",
      progress: 100,
      metadata: {
        "valid_count" => 5,
        "invalid_count" => 2,
        "verified_count" => 5,
        "validated_items" => 7
      }
    )

    render_inline(Admin::Music::Songs::Wizard::ValidateStepComponent.new(list: @list))

    assert_selector ".stat-title", text: "Auto-Verified"
    assert_selector ".stat-value", text: "5"
  end

  test "renders Retry Validation button when job failed" do
    set_validate_state(status: "failed", error: "Error")

    render_inline(Admin::Music::Songs::Wizard::ValidateStepComponent.new(list: @list))

    assert_selector "button", text: "Retry Validation"
  end

  test "renders Re-validate button when completed" do
    set_validate_state(
      status: "completed",
      progress: 100,
      metadata: {"validated_items" => 2}
    )

    render_inline(Admin::Music::Songs::Wizard::ValidateStepComponent.new(list: @list))

    assert_selector "button", text: "Re-validate Items"
  end

  test "shows success alert when completed" do
    set_validate_state(
      status: "completed",
      progress: 100,
      metadata: {"validated_items" => 2}
    )

    render_inline(Admin::Music::Songs::Wizard::ValidateStepComponent.new(list: @list))

    assert_selector ".alert-success"
    assert_text "Validation Complete!"
  end

  test "shows loading indicator when running" do
    set_validate_state(status: "running", progress: 0)

    render_inline(Admin::Music::Songs::Wizard::ValidateStepComponent.new(list: @list))

    assert_selector ".loading-spinner"
    assert_text "AI validation in progress"
  end

  test "displays match source badges in preview table" do
    set_validate_state(
      status: "completed",
      progress: 100,
      metadata: {"validated_items" => 2}
    )

    render_inline(Admin::Music::Songs::Wizard::ValidateStepComponent.new(list: @list))

    assert_selector ".badge", text: "OpenSearch"
    assert_selector ".badge", text: "MusicBrainz"
  end

  test "highlights invalid items with error background" do
    @list.list_items.unverified.second.update!(
      metadata: @list.list_items.unverified.second.metadata.merge("ai_match_invalid" => true)
    )

    set_validate_state(
      status: "completed",
      progress: 100,
      metadata: {"validated_items" => 2}
    )

    render_inline(Admin::Music::Songs::Wizard::ValidateStepComponent.new(list: @list))

    assert_selector "tr.bg-error\\/10"
  end

  test "shows percentage of valid and invalid matches" do
    set_validate_state(
      status: "completed",
      progress: 100,
      metadata: {
        "valid_count" => 8,
        "invalid_count" => 2,
        "validated_items" => 10
      }
    )

    render_inline(Admin::Music::Songs::Wizard::ValidateStepComponent.new(list: @list))

    assert_text "80.0% of validated"
    assert_text "20.0% of validated"
  end
end
