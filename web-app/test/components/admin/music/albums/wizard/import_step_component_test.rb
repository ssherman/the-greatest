# frozen_string_literal: true

require "test_helper"

class Admin::Music::Albums::Wizard::ImportStepComponentTest < ViewComponent::TestCase
  setup do
    @list = lists(:music_albums_list)
    @list.list_items.destroy_all

    3.times do |i|
      @list.list_items.create!(
        listable_type: "Music::Album",
        listable_id: nil,
        verified: false,
        position: i + 1,
        metadata: {
          "title" => "Album #{i + 1}",
          "artists" => ["Artist #{i + 1}"],
          "mb_release_group_id" => "mb-release-group-#{i + 1}"
        }
      )
    end
  end

  def set_import_state(import_source: "custom_html", status: "idle", progress: 0, error: nil, metadata: {})
    @list.update!(wizard_state: {
      "current_step" => 5,
      "import_source" => import_source,
      "steps" => {
        "import" => {
          "status" => status,
          "progress" => progress,
          "error" => error,
          "metadata" => metadata
        }
      }
    })
  end

  test "renders based on import_source in wizard_state" do
    set_import_state(import_source: "custom_html")

    render_inline(Admin::Music::Albums::Wizard::ImportStepComponent.new(list: @list))

    assert_text "Import albums from MusicBrainz based on matched release groups"
  end

  test "renders progress bar when job running" do
    set_import_state(
      status: "running",
      progress: 50,
      metadata: {"processed_items" => 50, "total_items" => 100}
    )

    render_inline(Admin::Music::Albums::Wizard::ImportStepComponent.new(list: @list))

    assert_selector "progress[value='50'][max='100']"
  end

  test "uses wizard-step controller when job is running" do
    set_import_state(status: "running", progress: 25)

    render_inline(Admin::Music::Albums::Wizard::ImportStepComponent.new(list: @list))

    assert_selector "[data-controller='wizard-step']"
  end

  test "does not use wizard-step controller when job is idle" do
    set_import_state(status: "idle")

    render_inline(Admin::Music::Albums::Wizard::ImportStepComponent.new(list: @list))

    assert_no_selector "[data-controller='wizard-step']"
  end

  test "renders error message when job failed" do
    set_import_state(status: "failed", error: "MusicBrainz API timeout")

    render_inline(Admin::Music::Albums::Wizard::ImportStepComponent.new(list: @list))

    assert_selector ".alert-error"
    assert_text "MusicBrainz API timeout"
  end

  test "custom_html: renders stats cards with correct counts" do
    @list.list_items.first.update!(listable_id: music_albums(:dark_side_of_the_moon).id)
    @list.list_items.last.update!(metadata: {"title" => "No Match"})

    set_import_state(status: "idle")

    render_inline(Admin::Music::Albums::Wizard::ImportStepComponent.new(list: @list))

    assert_selector ".stat-title", text: "Total Items"
    assert_selector ".stat-title", text: "Already Linked"
    assert_selector ".stat-title", text: "To Import"
    assert_selector ".stat-title", text: "Without Match"
  end

  test "custom_html: renders Start Import button when job idle" do
    set_import_state(status: "idle")

    render_inline(Admin::Music::Albums::Wizard::ImportStepComponent.new(list: @list))

    assert_selector "button", text: "Start Import"
  end

  test "custom_html: disables Start Import button when no items to import" do
    @list.list_items.each { |item| item.update!(metadata: {"title" => item.metadata["title"]}) }

    set_import_state(status: "idle")

    render_inline(Admin::Music::Albums::Wizard::ImportStepComponent.new(list: @list))

    assert_selector "button[disabled]", text: "Start Import"
  end

  test "custom_html: displays results summary when completed" do
    set_import_state(
      status: "completed",
      progress: 100,
      metadata: {
        "imported_count" => 2,
        "skipped_count" => 0,
        "failed_count" => 1,
        "total_items" => 3
      }
    )

    render_inline(Admin::Music::Albums::Wizard::ImportStepComponent.new(list: @list))

    assert_selector ".alert-success"
    assert_text "Import Complete!"
    assert_selector ".stat-value", text: "2"
  end

  test "custom_html: shows failed items section when failures exist" do
    set_import_state(
      status: "completed",
      progress: 100,
      metadata: {
        "imported_count" => 2,
        "failed_count" => 1,
        "errors" => [
          {"item_id" => 1, "title" => "Failed Album", "error" => "Release group not found"}
        ]
      }
    )

    render_inline(Admin::Music::Albums::Wizard::ImportStepComponent.new(list: @list))

    assert_text "View Failed Items"
    assert_text "Release group not found"
  end

  test "custom_html: shows items to import preview table" do
    set_import_state(status: "idle")

    render_inline(Admin::Music::Albums::Wizard::ImportStepComponent.new(list: @list))

    assert_text "Items to Import"
    assert_text "Album 1"
    assert_text "Artist 1"
  end

  test "custom_html: correctly categorizes linked vs unlinked items" do
    @list.list_items.first.update!(listable_id: music_albums(:dark_side_of_the_moon).id)

    set_import_state(status: "idle")

    render_inline(Admin::Music::Albums::Wizard::ImportStepComponent.new(list: @list))

    assert_selector ".stat-value", text: "1", count: 1
  end

  test "series: renders series info card with musicbrainz_series_id" do
    @list.update!(musicbrainz_series_id: "abc123-series-mbid")
    set_import_state(import_source: "musicbrainz_series")

    render_inline(Admin::Music::Albums::Wizard::ImportStepComponent.new(list: @list))

    assert_text "MusicBrainz Series Import"
    assert_text "abc123-series-mbid"
  end

  test "series: renders Import from Series button when job idle" do
    @list.update!(musicbrainz_series_id: "abc123-series-mbid")
    set_import_state(import_source: "musicbrainz_series")

    render_inline(Admin::Music::Albums::Wizard::ImportStepComponent.new(list: @list))

    assert_selector "button", text: "Import from Series"
  end

  test "series: displays series import results when completed" do
    @list.update!(musicbrainz_series_id: "abc123-series-mbid")
    set_import_state(
      import_source: "musicbrainz_series",
      status: "completed",
      progress: 100,
      metadata: {
        "imported_count" => 50,
        "list_items_created" => 50,
        "failed_count" => 2
      }
    )

    render_inline(Admin::Music::Albums::Wizard::ImportStepComponent.new(list: @list))

    assert_selector ".alert-success"
    assert_text "Series Import Complete!"
  end

  test "series: shows albums imported and list items created counts" do
    @list.update!(musicbrainz_series_id: "abc123-series-mbid")
    set_import_state(
      import_source: "musicbrainz_series",
      status: "completed",
      progress: 100,
      metadata: {
        "imported_count" => 50,
        "list_items_created" => 50
      }
    )

    render_inline(Admin::Music::Albums::Wizard::ImportStepComponent.new(list: @list))

    assert_selector ".stat-title", text: "Albums Imported"
    assert_selector ".stat-title", text: "List Items Created"
    assert_selector ".stat-value", text: "50", count: 2
  end

  test "renders Complete Wizard button when job completed" do
    set_import_state(
      status: "completed",
      progress: 100,
      metadata: {"imported_count" => 3}
    )

    render_inline(Admin::Music::Albums::Wizard::ImportStepComponent.new(list: @list))

    assert_selector "button", text: "Complete Wizard"
  end

  test "renders Retry Import button when job failed" do
    set_import_state(status: "failed", error: "Error")

    render_inline(Admin::Music::Albums::Wizard::ImportStepComponent.new(list: @list))

    assert_selector "button", text: "Retry Import"
  end

  test "shows loading indicator when running" do
    set_import_state(status: "running", progress: 50)

    render_inline(Admin::Music::Albums::Wizard::ImportStepComponent.new(list: @list))

    assert_selector ".loading-spinner"
    assert_text "Import in progress"
  end

  test "does not render Start Import button when job running" do
    set_import_state(status: "running", progress: 25)

    render_inline(Admin::Music::Albums::Wizard::ImportStepComponent.new(list: @list))

    assert_no_selector "button", text: "Start Import"
  end

  test "progress bar targets exist when running" do
    set_import_state(status: "running", progress: 50)

    render_inline(Admin::Music::Albums::Wizard::ImportStepComponent.new(list: @list))

    assert_selector "[data-wizard-step-target='progressBar']"
    assert_selector "[data-wizard-step-target='statusText']"
  end

  test "series: disables Import from Series button when no series id" do
    @list.update!(musicbrainz_series_id: nil)
    set_import_state(import_source: "musicbrainz_series")

    render_inline(Admin::Music::Albums::Wizard::ImportStepComponent.new(list: @list))

    assert_selector "button[disabled]", text: "Import from Series"
  end
end
