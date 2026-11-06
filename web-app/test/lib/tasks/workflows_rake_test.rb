# frozen_string_literal: true

require "test_helper"
require "rake"

class WorkflowsRakeTest < ActiveSupport::TestCase
  include Workflows::TestDefinitionHelpers
  include Workflows::DispatchHelper

  setup do
    unless Rake::Task.task_defined?("workflows:stuck")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/workflows.rake").to_s }
    end
    @task = Rake::Task["workflows:stuck"]
    @task.reenable
    # The fixture run's ready step would otherwise count once it is old.
    WorkflowRun.where(enrichable: books_authors(:tolstoy), status: :running).find_each do |fixture_run|
      Workflows::Coordinator.cancel(fixture_run, outcome: "test")
    end
    stub_workflow_dispatch
  end

  test "prints one line per stuck step, using the hours argument as the threshold" do
    workflow_run.step(:a).update_columns(state: WorkflowStep.states[:waiting], run_after: 3.hours.ago)

    assert_output(/No stuck workflow steps\./) { @task.invoke }
    @task.reenable
    output, = capture_io { @task.invoke("2") }
    assert_match(/test\.diamond\s+Books::Author #\d+\s+a\s+waiting/, output)
    assert_match(/1 stuck step\./, output)
  end

  test "books:workflows:adopt_deferred prints what it planned and passes the limit through" do
    ::Services::Books::DeferredEnrichment.defer!(books_books(:got))
    ::Services::Books::DeferredEnrichment.defer!(books_books(:war_and_peace))
    adopt = Rake::Task["books:workflows:adopt_deferred"]

    adopt.reenable
    assert_output(/Planned 1 book run\(s\); left 0 /) { adopt.invoke("1") }
    adopt.reenable
    assert_output(/Planned 1 book run\(s\); left 1 /) { adopt.invoke }
  end

  test "books:workflows:adopt_deferred aborts on a limit that is not positive" do
    adopt = Rake::Task["books:workflows:adopt_deferred"]
    adopt.reenable

    assert_raises(SystemExit) { capture_io { adopt.invoke("0") } }
  end
end
