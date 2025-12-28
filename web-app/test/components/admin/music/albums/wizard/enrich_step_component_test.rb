# frozen_string_literal: true

require "test_helper"

class Admin::Music::Albums::Wizard::EnrichStepComponentTest < ViewComponent::TestCase
  setup do
    @list = lists(:music_albums_list)
    @list.list_items.unverified.destroy_all

    3.times do |i|
      @list.list_items.create!(
        listable_type: "Music::Album",
        verified: false,
        position: i + 1,
        metadata: {"title" => "Album #{i + 1}", "artists" => ["Artist #{i + 1}"]}
      )
    end
  end

  # Helper to set step-namespaced wizard state for enrich step
  def set_enrich_state(status:, progress: 0, error: nil, metadata: {})
    @list.update!(wizard_state: {
      "current_step" => 2,
      "steps" => {
        "enrich" => {
          "status" => status,
          "progress" => progress,
          "error" => error,
          "metadata" => metadata
        }
      }
    })
  end

  test "renders stats cards" do
    set_enrich_state(status: "idle")

    render_inline(Admin::Music::Albums::Wizard::EnrichStepComponent.new(list: @list))

    assert_selector ".stat-title", text: "Total Items"
    assert_selector ".stat-value", text: "3"
  end

  test "renders progress bar with current progress" do
    set_enrich_state(
      status: "running",
      progress: 50,
      metadata: {"processed_items" => 50, "total_items" => 100}
    )

    render_inline(Admin::Music::Albums::Wizard::EnrichStepComponent.new(list: @list))

    assert_selector "progress[value='50'][max='100']"
  end

  test "renders Start Enrichment button when job idle" do
    set_enrich_state(status: "idle")

    render_inline(Admin::Music::Albums::Wizard::EnrichStepComponent.new(list: @list))

    assert_selector "button", text: "Start Enrichment"
  end

  test "does not render Start Enrichment button when job running" do
    set_enrich_state(status: "running", progress: 25)

    render_inline(Admin::Music::Albums::Wizard::EnrichStepComponent.new(list: @list))

    assert_no_selector "button", text: "Start Enrichment"
  end

  test "renders error message when job failed" do
    set_enrich_state(status: "failed", error: "MusicBrainz API error")

    render_inline(Admin::Music::Albums::Wizard::EnrichStepComponent.new(list: @list))

    assert_selector ".alert-error"
    assert_text "MusicBrainz API error"
  end

  test "uses wizard-step controller when job is running" do
    set_enrich_state(status: "running", progress: 25)

    render_inline(Admin::Music::Albums::Wizard::EnrichStepComponent.new(list: @list))

    assert_selector "[data-controller='wizard-step']"
  end

  test "does not use wizard-step controller when job is idle" do
    set_enrich_state(status: "idle")

    render_inline(Admin::Music::Albums::Wizard::EnrichStepComponent.new(list: @list))

    assert_no_selector "[data-controller='wizard-step']"
  end

  test "displays item preview table when completed" do
    set_enrich_state(
      status: "completed",
      progress: 100,
      metadata: {"opensearch_matches" => 2, "musicbrainz_matches" => 1, "not_found" => 0, "total_items" => 3}
    )

    render_inline(Admin::Music::Albums::Wizard::EnrichStepComponent.new(list: @list))

    assert_selector "table"
    assert_text "Enriched Items"
  end

  test "shows correct match percentages in stats" do
    set_enrich_state(
      status: "completed",
      progress: 100,
      metadata: {
        "opensearch_matches" => 6,
        "musicbrainz_matches" => 3,
        "not_found" => 1,
        "total_items" => 10
      }
    )

    render_inline(Admin::Music::Albums::Wizard::EnrichStepComponent.new(list: @list))

    assert_text "60.0% of items"
    assert_text "30.0% of items"
    assert_text "10.0% of items"
  end

  test "renders Retry Enrichment button when job failed" do
    set_enrich_state(status: "failed", error: "Error")

    render_inline(Admin::Music::Albums::Wizard::EnrichStepComponent.new(list: @list))

    assert_selector "button", text: "Retry Enrichment"
  end

  test "renders Re-enrich button when completed" do
    set_enrich_state(
      status: "completed",
      progress: 100,
      metadata: {"total_items" => 3}
    )

    render_inline(Admin::Music::Albums::Wizard::EnrichStepComponent.new(list: @list))

    assert_selector "button", text: "Re-enrich Items"
  end

  test "shows success alert when completed" do
    set_enrich_state(
      status: "completed",
      progress: 100,
      metadata: {"total_items" => 3}
    )

    render_inline(Admin::Music::Albums::Wizard::EnrichStepComponent.new(list: @list))

    assert_selector ".alert-success"
    assert_text "Enrichment Complete!"
  end

  test "shows loading indicator when running" do
    set_enrich_state(status: "running", progress: 50)

    render_inline(Admin::Music::Albums::Wizard::EnrichStepComponent.new(list: @list))

    assert_selector ".loading-spinner"
    assert_text "Enrichment in progress"
  end

  test "displays match source badges in preview table" do
    @list.list_items.unverified.first.update!(metadata: {
      "title" => "Album 1",
      "artists" => ["Artist 1"],
      "opensearch_match" => true
    })
    @list.list_items.unverified.second.update!(metadata: {
      "title" => "Album 2",
      "artists" => ["Artist 2"],
      "musicbrainz_match" => true
    })

    set_enrich_state(
      status: "completed",
      progress: 100,
      metadata: {"total_items" => 3}
    )

    render_inline(Admin::Music::Albums::Wizard::EnrichStepComponent.new(list: @list))

    assert_selector ".badge", text: "OpenSearch"
    assert_selector ".badge", text: "MusicBrainz"
  end

  test "displays MBID Found badge for musicbrainz match without local album" do
    @list.list_items.unverified.first.update!(metadata: {
      "title" => "Album 1",
      "artists" => ["Artist 1"],
      "musicbrainz_match" => true,
      "mb_release_group_id" => "abc123"
    })

    set_enrich_state(
      status: "completed",
      progress: 100,
      metadata: {"total_items" => 3}
    )

    render_inline(Admin::Music::Albums::Wizard::EnrichStepComponent.new(list: @list))

    assert_selector ".badge", text: "MBID Found"
  end
end
