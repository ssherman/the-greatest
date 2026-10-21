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
    workflow_run.step(:a).update_columns(state: WorkflowStep.states[:waiting], updated_at: 3.hours.ago)

    assert_output(/No stuck workflow steps\./) { @task.invoke }
    @task.reenable
    output, = capture_io { @task.invoke("2") }
    assert_match(/test\.diamond\s+Books::Author #\d+\s+a\s+waiting/, output)
    assert_match(/1 stuck step\./, output)
  end
end
