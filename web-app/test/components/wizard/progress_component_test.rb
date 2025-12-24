# frozen_string_literal: true

require "test_helper"

class Wizard::ProgressComponentTest < ViewComponent::TestCase
  setup do
    @steps = [
      {name: "source", step: 0},
      {name: "parse", step: 1},
      {name: "enrich", step: 2},
      {name: "validate", step: 3},
      {name: "review", step: 4}
    ]
  end

  test "renders all steps" do
    render_inline(Wizard::ProgressComponent.new(
      steps: @steps,
      current_step: 2
    ))

    assert_selector ".steps .step", count: 5
  end

  test "highlights current step with primary class" do
    render_inline(Wizard::ProgressComponent.new(
      steps: @steps,
      current_step: 2
    ))

    assert_selector ".step.step-primary", count: 3
  end

  test "displays numbers for pending and current steps" do
    render_inline(Wizard::ProgressComponent.new(
      steps: @steps,
      current_step: 2
    ))

    # Steps 3, 4, 5 should show numbers (current is index 2, so steps 3, 4, 5)
    assert_selector ".step[data-content='3']"
    assert_selector ".step[data-content='4']"
    assert_selector ".step[data-content='5']"
  end

  test "displays checkmarks for completed steps" do
    render_inline(Wizard::ProgressComponent.new(
      steps: @steps,
      current_step: 2
    ))

    # Steps 0, 1 (index < current_step) should show checkmarks
    assert_selector ".step[data-content='✓']", count: 2
  end

  test "displays step names" do
    render_inline(Wizard::ProgressComponent.new(
      steps: @steps,
      current_step: 0
    ))

    assert_selector ".step", text: "Source"
    assert_selector ".step", text: "Parse"
    assert_selector ".step", text: "Enrich"
  end

  test "filters steps based on import source" do
    steps_with_parse = [
      {name: "source", step: 0},
      {name: "parse", step: 1},
      {name: "enrich", step: 2}
    ]

    component = Wizard::ProgressComponent.new(
      steps: steps_with_parse,
      current_step: 0,
      import_source: "custom_html"
    )

    assert_equal 3, component.filtered_steps.count
  end
end
