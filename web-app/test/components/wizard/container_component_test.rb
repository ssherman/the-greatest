# frozen_string_literal: true

require "test_helper"

class Wizard::ContainerComponentTest < ViewComponent::TestCase
  test "renders wizard container with correct ID" do
    render_inline(Wizard::ContainerComponent.new(
      wizard_id: "test_wizard",
      current_step: 1,
      total_steps: 5
    ))

    assert_selector "#test_wizard.wizard-container"
  end

  test "renders header slot content" do
    render_inline(Wizard::ContainerComponent.new(
      wizard_id: "test_wizard",
      current_step: 1,
      total_steps: 5
    )) do |component|
      component.with_header { "Test Header" }
    end

    assert_selector ".wizard-header", text: "Test Header"
  end

  test "renders progress slot content" do
    render_inline(Wizard::ContainerComponent.new(
      wizard_id: "test_wizard",
      current_step: 1,
      total_steps: 5
    )) do |component|
      component.with_progress { "Progress Bar" }
    end

    assert_selector ".wizard-progress", text: "Progress Bar"
  end

  test "renders navigation slot content" do
    render_inline(Wizard::ContainerComponent.new(
      wizard_id: "test_wizard",
      current_step: 1,
      total_steps: 5
    )) do |component|
      component.with_navigation { "Navigation Buttons" }
    end

    assert_selector ".wizard-navigation", text: "Navigation Buttons"
  end

  test "renders all slots together" do
    render_inline(Wizard::ContainerComponent.new(
      wizard_id: "test_wizard",
      current_step: 1,
      total_steps: 5
    )) do |component|
      component.with_header { "Header" }
      component.with_progress { "Progress" }
      component.with_navigation { "Navigation" }
    end

    assert_selector ".wizard-header", text: "Header"
    assert_selector ".wizard-progress", text: "Progress"
    assert_selector ".wizard-navigation", text: "Navigation"
  end
end
