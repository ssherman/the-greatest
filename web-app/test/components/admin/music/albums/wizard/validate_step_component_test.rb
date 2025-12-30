# frozen_string_literal: true

require "test_helper"

class Admin::Music::Albums::Wizard::ValidateStepComponentTest < ViewComponent::TestCase
  setup do
    @list = lists(:music_albums_list)
    @list.update!(wizard_state: {"current_step" => 3, "steps" => {"validate" => {"status" => "idle"}}})

    @list.list_items.destroy_all

    @list.list_items.create!(
      position: 1,
      verified: false,
      metadata: {
        "title" => "The Dark Side of the Moon",
        "artists" => ["Pink Floyd"],
        "album_id" => 123,
        "album_name" => "The Dark Side of the Moon",
        "opensearch_artist_names" => ["Pink Floyd"],
        "opensearch_match" => true
      }
    )
  end

  test "renders idle state with start validation button" do
    component = Admin::Music::Albums::Wizard::ValidateStepComponent.new(list: @list)
    render_inline(component)

    assert_selector "button", text: "Start Validation"
    assert_selector ".stat-value", text: "1"
  end

  test "renders running state with progress" do
    @list.wizard_manager.update_step_status!(step: "validate", status: "running", progress: 50, metadata: {})
    component = Admin::Music::Albums::Wizard::ValidateStepComponent.new(list: @list)
    render_inline(component)

    assert_selector "progress[value='50']"
    assert_selector ".loading-spinner"
  end

  test "renders completed state with stats" do
    @list.wizard_manager.update_step_status!(
      step: "validate",
      status: "completed",
      progress: 100,
      metadata: {
        "validated_items" => 1,
        "valid_count" => 1,
        "invalid_count" => 0,
        "verified_count" => 1,
        "reasoning" => "All matches valid"
      }
    )
    component = Admin::Music::Albums::Wizard::ValidateStepComponent.new(list: @list)
    render_inline(component)

    assert_selector ".alert-success"
    assert_selector "button", text: "Re-validate Items"
  end

  test "renders failed state with error and retry button" do
    @list.wizard_manager.update_step_status!(
      step: "validate",
      status: "failed",
      progress: 0,
      error: "AI service unavailable"
    )
    component = Admin::Music::Albums::Wizard::ValidateStepComponent.new(list: @list)
    render_inline(component)

    assert_selector ".alert-error", text: "AI service unavailable"
    assert_selector "button", text: "Retry Validation"
  end

  test "idle_or_failed? returns true for idle status" do
    component = Admin::Music::Albums::Wizard::ValidateStepComponent.new(list: @list)
    assert component.send(:idle_or_failed?)
  end

  test "idle_or_failed? returns true for failed status" do
    @list.wizard_manager.update_step_status!(step: "validate", status: "failed", progress: 0, error: "Error")
    component = Admin::Music::Albums::Wizard::ValidateStepComponent.new(list: @list)
    assert component.send(:idle_or_failed?)
  end

  test "running? returns true when status is running" do
    @list.wizard_manager.update_step_status!(step: "validate", status: "running", progress: 50, metadata: {})
    component = Admin::Music::Albums::Wizard::ValidateStepComponent.new(list: @list)
    assert component.send(:running?)
  end

  test "completed? returns true when status is completed" do
    @list.wizard_manager.update_step_status!(step: "validate", status: "completed", progress: 100, metadata: {})
    component = Admin::Music::Albums::Wizard::ValidateStepComponent.new(list: @list)
    assert component.send(:completed?)
  end

  test "percentage calculates correctly" do
    @list.wizard_manager.update_step_status!(
      step: "validate",
      status: "completed",
      progress: 100,
      metadata: {"validated_items" => 10, "valid_count" => 7, "invalid_count" => 3}
    )
    component = Admin::Music::Albums::Wizard::ValidateStepComponent.new(list: @list)
    assert_equal 70.0, component.send(:percentage, 7)
    assert_equal 30.0, component.send(:percentage, 3)
  end

  test "percentage returns 0 when no validated items" do
    component = Admin::Music::Albums::Wizard::ValidateStepComponent.new(list: @list)
    assert_equal 0, component.send(:percentage, 5)
  end
end
