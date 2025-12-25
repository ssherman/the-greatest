# frozen_string_literal: true

require "test_helper"

class Wizard::NavigationComponentTest < ViewComponent::TestCase
  setup do
    @list = lists(:music_songs_list)
    # Use step-namespaced structure (legacy wizard_job_status delegates to current step)
    @list.update!(wizard_state: {
      "current_step" => 0,
      "steps" => {"source" => {"status" => "idle"}}
    })
  end

  test "show_back_button? returns true when not on first step" do
    component = Wizard::NavigationComponent.new(
      list: @list,
      step_name: "parse",
      step_index: 1,
      total_steps: 5,
      back_enabled: true,
      next_enabled: true
    )

    assert component.show_back_button?
  end

  test "show_back_button? returns false on first step" do
    component = Wizard::NavigationComponent.new(
      list: @list,
      step_name: "source",
      step_index: 0,
      total_steps: 5,
      back_enabled: true,
      next_enabled: true
    )

    assert_not component.show_back_button?
  end

  test "show_next_button? returns true when not on last step" do
    component = Wizard::NavigationComponent.new(
      list: @list,
      step_name: "parse",
      step_index: 1,
      total_steps: 5,
      back_enabled: true,
      next_enabled: true
    )

    assert component.show_next_button?
  end

  test "show_next_button? returns false on last step" do
    component = Wizard::NavigationComponent.new(
      list: @list,
      step_name: "complete",
      step_index: 4,
      total_steps: 5,
      back_enabled: true,
      next_enabled: true
    )

    assert_not component.show_next_button?
  end

  test "next_button_disabled? returns true when job is running" do
    # Use step-namespaced structure with current_step matching the step_index
    @list.update!(wizard_state: {
      "current_step" => 1,  # parse step
      "steps" => {"parse" => {"status" => "running"}}
    })

    component = Wizard::NavigationComponent.new(
      list: @list,
      step_name: "parse",
      step_index: 1,
      total_steps: 5,
      back_enabled: true,
      next_enabled: true
    )

    assert component.next_button_disabled?
  end

  test "next_button_disabled? returns true when next_enabled is false" do
    component = Wizard::NavigationComponent.new(
      list: @list,
      step_name: "parse",
      step_index: 1,
      total_steps: 5,
      back_enabled: true,
      next_enabled: false
    )

    assert component.next_button_disabled?
  end

  test "next_button_disabled? returns false when ready to advance" do
    component = Wizard::NavigationComponent.new(
      list: @list,
      step_name: "parse",
      step_index: 1,
      total_steps: 5,
      back_enabled: true,
      next_enabled: true
    )

    assert_not component.next_button_disabled?
  end
end
