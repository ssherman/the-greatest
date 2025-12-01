# frozen_string_literal: true

require "test_helper"

class Admin::Music::Songs::Wizard::EnrichStepComponentTest < ViewComponent::TestCase
  setup do
    @list = lists(:music_songs_list)
    @list.list_items.unverified.destroy_all

    3.times do |i|
      @list.list_items.create!(
        listable_type: "Music::Song",
        verified: false,
        position: i + 1,
        metadata: {"title" => "Song #{i + 1}", "artists" => ["Artist #{i + 1}"]}
      )
    end
  end

  test "renders stats cards" do
    @list.update!(wizard_state: {"job_status" => "idle"})

    render_inline(Admin::Music::Songs::Wizard::EnrichStepComponent.new(list: @list))

    assert_selector ".stat-title", text: "Total Items"
    assert_selector ".stat-value", text: "3"
  end

  test "renders progress bar with current progress" do
    @list.update!(wizard_state: {
      "job_status" => "running",
      "job_progress" => 50,
      "job_metadata" => {"processed_items" => 50, "total_items" => 100}
    })

    render_inline(Admin::Music::Songs::Wizard::EnrichStepComponent.new(list: @list))

    assert_selector "progress[value='50'][max='100']"
  end

  test "renders Start Enrichment button when job idle" do
    @list.update!(wizard_state: {"job_status" => "idle"})

    render_inline(Admin::Music::Songs::Wizard::EnrichStepComponent.new(list: @list))

    assert_selector "button", text: "Start Enrichment"
  end

  test "does not render Start Enrichment button when job running" do
    @list.update!(wizard_state: {"job_status" => "running", "job_progress" => 25})

    render_inline(Admin::Music::Songs::Wizard::EnrichStepComponent.new(list: @list))

    assert_no_selector "button", text: "Start Enrichment"
  end

  test "renders error message when job failed" do
    @list.update!(wizard_state: {"job_status" => "failed", "job_error" => "MusicBrainz API error"})

    render_inline(Admin::Music::Songs::Wizard::EnrichStepComponent.new(list: @list))

    assert_selector ".alert-error"
    assert_text "MusicBrainz API error"
  end

  test "uses wizard-step controller when job is running" do
    @list.update!(wizard_state: {"job_status" => "running", "job_progress" => 25})

    render_inline(Admin::Music::Songs::Wizard::EnrichStepComponent.new(list: @list))

    assert_selector "[data-controller='wizard-step']"
  end

  test "does not use wizard-step controller when job is idle" do
    @list.update!(wizard_state: {"job_status" => "idle"})

    render_inline(Admin::Music::Songs::Wizard::EnrichStepComponent.new(list: @list))

    assert_no_selector "[data-controller='wizard-step']"
  end

  test "displays item preview table when completed" do
    @list.update!(wizard_state: {
      "job_status" => "completed",
      "job_progress" => 100,
      "job_metadata" => {"opensearch_matches" => 2, "musicbrainz_matches" => 1, "not_found" => 0, "total_items" => 3}
    })

    render_inline(Admin::Music::Songs::Wizard::EnrichStepComponent.new(list: @list))

    assert_selector "table"
    assert_text "Enriched Items"
  end

  test "shows correct match percentages in stats" do
    @list.update!(wizard_state: {
      "job_status" => "completed",
      "job_progress" => 100,
      "job_metadata" => {
        "opensearch_matches" => 6,
        "musicbrainz_matches" => 3,
        "not_found" => 1,
        "total_items" => 10
      }
    })

    render_inline(Admin::Music::Songs::Wizard::EnrichStepComponent.new(list: @list))

    assert_text "60.0% of items"
    assert_text "30.0% of items"
    assert_text "10.0% of items"
  end

  test "renders Retry Enrichment button when job failed" do
    @list.update!(wizard_state: {"job_status" => "failed", "job_error" => "Error"})

    render_inline(Admin::Music::Songs::Wizard::EnrichStepComponent.new(list: @list))

    assert_selector "button", text: "Retry Enrichment"
  end

  test "renders Re-enrich button when completed" do
    @list.update!(wizard_state: {
      "job_status" => "completed",
      "job_progress" => 100,
      "job_metadata" => {"total_items" => 3}
    })

    render_inline(Admin::Music::Songs::Wizard::EnrichStepComponent.new(list: @list))

    assert_selector "button", text: "Re-enrich Items"
  end

  test "shows success alert when completed" do
    @list.update!(wizard_state: {
      "job_status" => "completed",
      "job_progress" => 100,
      "job_metadata" => {"total_items" => 3}
    })

    render_inline(Admin::Music::Songs::Wizard::EnrichStepComponent.new(list: @list))

    assert_selector ".alert-success"
    assert_text "Enrichment Complete!"
  end

  test "shows loading indicator when running" do
    @list.update!(wizard_state: {"job_status" => "running", "job_progress" => 50})

    render_inline(Admin::Music::Songs::Wizard::EnrichStepComponent.new(list: @list))

    assert_selector ".loading-spinner"
    assert_text "Enrichment in progress"
  end

  test "displays match source badges in preview table" do
    @list.list_items.unverified.first.update!(metadata: {
      "title" => "Song 1",
      "artists" => ["Artist 1"],
      "opensearch_match" => true
    })
    @list.list_items.unverified.second.update!(metadata: {
      "title" => "Song 2",
      "artists" => ["Artist 2"],
      "musicbrainz_match" => true
    })

    @list.update!(wizard_state: {
      "job_status" => "completed",
      "job_progress" => 100,
      "job_metadata" => {"total_items" => 3}
    })

    render_inline(Admin::Music::Songs::Wizard::EnrichStepComponent.new(list: @list))

    assert_selector ".badge", text: "OpenSearch"
    assert_selector ".badge", text: "MusicBrainz"
  end
end
