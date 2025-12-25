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

  test "excludes parse step for musicbrainz_series import source" do
    steps = [
      {name: "source", step: 0},
      {name: "parse", step: 1},
      {name: "enrich", step: 2},
      {name: "validate", step: 3},
      {name: "review", step: 4},
      {name: "import", step: 5},
      {name: "complete", step: 6}
    ]

    component = Wizard::ProgressComponent.new(
      steps: steps,
      current_step: 5,
      import_source: "musicbrainz_series"
    )

    # Parse step should be excluded
    assert_equal 6, component.filtered_steps.count
    assert_not component.filtered_steps.any? { |s| s[:name] == "parse" }
  end

  test "highlights correct step when steps are filtered for musicbrainz_series" do
    # This tests the index alignment bug: when parse is filtered out,
    # the import step (original index 5) should still be current,
    # not the complete step (which would be at filtered index 5)
    steps = [
      {name: "source", step: 0},
      {name: "parse", step: 1},
      {name: "enrich", step: 2},
      {name: "validate", step: 3},
      {name: "review", step: 4},
      {name: "import", step: 5},
      {name: "complete", step: 6}
    ]

    render_inline(Wizard::ProgressComponent.new(
      steps: steps,
      current_step: 5,  # Import step is current
      import_source: "musicbrainz_series"
    ))

    # Should have 6 steps displayed (parse is filtered out)
    assert_selector ".step", count: 6

    # Import step should be current (highlighted with step-primary and showing "5")
    # NOT the complete step which happens to be at filtered position 5
    import_step = page.find(".step", text: "Import")
    complete_step = page.find(".step", text: "Complete")

    # Import should have step-primary class and show as current (number "5")
    assert_includes import_step["class"], "step-primary"
    assert_equal "5", import_step["data-content"]

    # Complete step should NOT have step-primary class (it's not reached yet)
    assert_not_includes complete_step["class"], "step-primary"
    assert_equal "6", complete_step["data-content"]
  end

  test "shows correct icons when steps are filtered" do
    steps = [
      {name: "source", step: 0},
      {name: "parse", step: 1},
      {name: "enrich", step: 2},
      {name: "validate", step: 3},
      {name: "review", step: 4},
      {name: "import", step: 5},
      {name: "complete", step: 6}
    ]

    render_inline(Wizard::ProgressComponent.new(
      steps: steps,
      current_step: 2,  # Enrich step is current
      import_source: "musicbrainz_series"
    ))

    # Source (step 0) should show checkmark (completed)
    source_step = page.find(".step", text: "Source")
    assert_equal "✓", source_step["data-content"]

    # Enrich (step 2) should show number "2" (current - numbers are 1-based display)
    enrich_step = page.find(".step", text: "Enrich")
    assert_equal "2", enrich_step["data-content"]

    # Validate (step 3) should show number "3" (pending)
    validate_step = page.find(".step", text: "Validate")
    assert_equal "3", validate_step["data-content"]
  end
end
