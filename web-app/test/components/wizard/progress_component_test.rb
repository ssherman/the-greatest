# frozen_string_literal: true

require "test_helper"

class Wizard::ProgressComponentTest < ViewComponent::TestCase
  setup do
    @steps = [
      {name: "source", step: 0, icon: "📁"},
      {name: "parse", step: 1, icon: "📝"},
      {name: "enrich", step: 2, icon: "✨"},
      {name: "validate", step: 3, icon: "✓"},
      {name: "review", step: 4, icon: "👁"}
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

  test "displays step icons" do
    render_inline(Wizard::ProgressComponent.new(
      steps: @steps,
      current_step: 0
    ))

    assert_selector ".step[data-content='📁']"
    assert_selector ".step[data-content='📝']"
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
      {name: "source", step: 0, icon: "📁"},
      {name: "parse", step: 1, icon: "📝"},
      {name: "enrich", step: 2, icon: "✨"}
    ]

    component = Wizard::ProgressComponent.new(
      steps: steps_with_parse,
      current_step: 0,
      import_source: "custom_html"
    )

    assert_equal 3, component.filtered_steps.count
  end
end
