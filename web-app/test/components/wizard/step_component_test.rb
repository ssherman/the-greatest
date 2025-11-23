# frozen_string_literal: true

require "test_helper"

class Wizard::StepComponentTest < ViewComponent::TestCase
  test "renders step with title" do
    render_inline(Wizard::StepComponent.new(title: "Test Step"))

    assert_selector "h2", text: "Test Step"
  end

  test "renders step with description" do
    render_inline(Wizard::StepComponent.new(
      title: "Test Step",
      description: "This is a test description"
    ))

    assert_selector "p", text: "This is a test description"
  end

  test "renders step with step number" do
    render_inline(Wizard::StepComponent.new(
      title: "Test Step",
      step_number: 3
    ))

    assert_selector "div", text: "Step 3"
  end

  test "renders active step with active class" do
    render_inline(Wizard::StepComponent.new(
      title: "Test Step",
      active: true
    ))

    assert_selector ".wizard-step.wizard-step-active"
  end

  test "renders inactive step without active class" do
    render_inline(Wizard::StepComponent.new(
      title: "Test Step",
      active: false
    ))

    assert_selector ".wizard-step"
    assert_no_selector ".wizard-step-active"
  end

  test "renders step_content slot" do
    render_inline(Wizard::StepComponent.new(title: "Test Step")) do |component|
      component.with_step_content { "Step Content Goes Here" }
    end

    assert_selector ".wizard-step-content", text: "Step Content Goes Here"
  end

  test "renders actions slot" do
    render_inline(Wizard::StepComponent.new(title: "Test Step")) do |component|
      component.with_actions { "Action Buttons" }
    end

    assert_selector ".wizard-step-actions", text: "Action Buttons"
  end
end
