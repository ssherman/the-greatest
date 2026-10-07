# frozen_string_literal: true

require "test_helper"

class Wizard::Core::JobStepComponentTest < ViewComponent::TestCase
  include ListWizardHelper

  setup do
    @list = wizard_list
    @adapter = ::Services::Lists::Wizard::Books::Adapter.new
  end

  def render_step(step) = render_inline(Wizard::Core::JobStepComponent.new(list: @list, adapter: @adapter, step: step))

  test "a running step polls its status and reloads its own page" do
    @list.wizard_manager.write_step!(step: "match", status: "running", progress: 40)

    render_step("match")

    assert_selector "[data-controller=wizard-step][data-wizard-step-status-url-value='#{@adapter.wizard_path(:step_status, @list, step: "match")}'][data-wizard-step-step-url-value='#{@adapter.wizard_path(:step, @list, step: "match")}']"
    assert_selector "progress[data-wizard-step-target=progressBar][value='40']"
    assert_selector "[data-wizard-step-target=percentText]", text: "40%"
  end

  test "an idle step offers to start it, a failed one shows its error and offers to retry" do
    render_step("parse")
    assert_selector "form[action='#{@adapter.wizard_path(:advance_step, @list, step: "parse")}']"

    @list.wizard_manager.write_step!(step: "parse", status: "failed", error: "rate limited")
    render_step("parse")
    assert_selector "[role=alert]", text: "rate limited"
    assert_selector "form[action='#{@adapter.wizard_path(:advance_step, @list, step: "parse")}']"
  end

  test "a completed parse lists the parsed rows, without removed ones, and offers a re-parse" do
    wizard_row(@list, position: 1, title: "Emma", authors: ["Jane Austen"])
    wizard_row(@list, position: 2, title: "Gone", wizard: {bucket: "removed", settled: true})
    @list.wizard_manager.write_step!(step: "parse", status: "completed", progress: 100)

    render_step("parse")

    assert_selector "[data-testid=parsed-rows] tbody tr", count: 1
    assert_selector "form[action='#{@adapter.wizard_path(:reparse, @list)}']"
  end

  test "a completed match shows its counts and offers a re-match; a completed import shows its summary" do
    wizard_row(@list, position: 1, title: "Emma", wizard: {bucket: "flagged", reasons: ["unsure"]})
    @list.wizard_manager.write_step!(step: "match", status: "completed", progress: 100)
    @list.wizard_manager.write_step!(step: "import", status: "completed", progress: 100, metadata: {"processed_items" => 3, "failed_count" => 1})

    render_step("match")
    assert_selector "[data-testid=match-counts] [data-stat=flagged] .stat-value", text: "1"
    assert_selector "form[action='#{@adapter.wizard_path(:rematch, @list)}']"

    render_step("import")
    assert_selector "[data-testid=import-summary] [data-stat=failed] .stat-value", text: "1"
    assert_selector "[data-testid=import-summary] [data-stat=processed] .stat-value", text: "3"
  end
end
