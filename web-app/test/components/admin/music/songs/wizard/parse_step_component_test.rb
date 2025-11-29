# frozen_string_literal: true

require "test_helper"

class Admin::Music::Songs::Wizard::ParseStepComponentTest < ViewComponent::TestCase
  setup do
    @list = lists(:music_songs_list)
    @list.update!(raw_html: "Sample HTML content for testing")
  end

  test "renders HTML preview" do
    render_inline(Admin::Music::Songs::Wizard::ParseStepComponent.new(list: @list))

    assert_text "HTML Preview"
    assert_text "Sample HTML content"
  end

  test "renders progress bar with current progress" do
    @list.update!(wizard_state: {"job_progress" => 50})

    render_inline(Admin::Music::Songs::Wizard::ParseStepComponent.new(list: @list))

    assert_selector "progress[value='50'][max='100']"
  end

  test "renders Start Parsing button when job idle" do
    @list.update!(wizard_state: {"job_status" => "idle"})

    render_inline(Admin::Music::Songs::Wizard::ParseStepComponent.new(list: @list))

    assert_selector "button", text: "Start Parsing"
  end

  test "does not render Start Parsing button when job running" do
    @list.update!(wizard_state: {"job_status" => "running"})

    render_inline(Admin::Music::Songs::Wizard::ParseStepComponent.new(list: @list))

    assert_no_selector "button", text: "Start Parsing"
  end

  test "renders error message when job failed" do
    @list.update!(wizard_state: {"job_status" => "failed", "job_error" => "Test error message"})

    render_inline(Admin::Music::Songs::Wizard::ParseStepComponent.new(list: @list))

    assert_selector ".alert-error"
    assert_text "Test error message"
  end

  test "uses wizard-step controller when job is running" do
    @list.update!(wizard_state: {"job_status" => "running"})

    render_inline(Admin::Music::Songs::Wizard::ParseStepComponent.new(list: @list))

    assert_selector "[data-controller='wizard-step']"
  end

  test "does not use wizard-step controller when job is idle" do
    @list.update!(wizard_state: {"job_status" => "idle"})

    render_inline(Admin::Music::Songs::Wizard::ParseStepComponent.new(list: @list))

    assert_no_selector "[data-controller='wizard-step']"
  end

  test "displays status text for idle job" do
    @list.update!(wizard_state: {"job_status" => "idle"})

    render_inline(Admin::Music::Songs::Wizard::ParseStepComponent.new(list: @list))

    assert_text "Ready to parse"
  end

  test "displays status text for running job" do
    @list.update!(wizard_state: {"job_status" => "running"})

    render_inline(Admin::Music::Songs::Wizard::ParseStepComponent.new(list: @list))

    assert_text "Parsing HTML..."
  end

  test "displays success message for completed job with parsed items" do
    @list.update!(wizard_state: {
      "job_status" => "completed",
      "job_progress" => 100,
      "job_metadata" => {"total_items" => 42}
    })
    # Create some unverified list items to show the parsed count
    @list.list_items.unverified.destroy_all
    5.times do |i|
      @list.list_items.create!(
        listable_type: "Music::Song",
        verified: false,
        position: i + 1,
        metadata: {"title" => "Song #{i + 1}", "artists" => ["Artist"]}
      )
    end

    render_inline(Admin::Music::Songs::Wizard::ParseStepComponent.new(list: @list, parsed_count: 5))

    assert_text "Parsing Complete!"
    assert_text "Successfully parsed 5 items"
  end

  test "truncates long HTML preview" do
    long_html = "a" * 600
    @list.update!(raw_html: long_html)

    render_inline(Admin::Music::Songs::Wizard::ParseStepComponent.new(list: @list))

    assert_text "... (truncated)"
  end
end
