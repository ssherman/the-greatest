require "test_helper"

# == Schema Information
#
# Table name: workflow_steps
#
#  id               :bigint           not null, primary key
#  attempts         :integer          default(0), not null
#  dispatch_count   :integer          default(0), not null
#  dispatched_at    :datetime
#  error            :text
#  finished_at      :datetime
#  key              :string           not null
#  lease_expires_at :datetime
#  lease_seconds    :integer          not null
#  lease_token      :string
#  max_attempts     :integer          default(3), not null
#  outcome          :string
#  queue            :string           not null
#  released_at      :datetime
#  result           :jsonb            not null
#  run_after        :datetime
#  started_at       :datetime
#  state            :integer          default("blocked"), not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  workflow_run_id  :bigint           not null
#
# Indexes
#
#  index_workflow_steps_on_state_and_dispatched_at     (state,dispatched_at)
#  index_workflow_steps_on_state_and_lease_expires_at  (state,lease_expires_at)
#  index_workflow_steps_on_state_and_run_after         (state,run_after)
#  index_workflow_steps_on_workflow_run_id_and_key     (workflow_run_id,key) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (workflow_run_id => workflow_runs.id)
#
class WorkflowStepTest < ActiveSupport::TestCase
  test "terminal? is true for succeeded, skipped and failed only" do
    step = workflow_steps(:tolstoy_wikidata)
    assert_equal [false, false, false, false, true, true, true],
      WorkflowStep.states.keys.map { |state| step.tap { it.state = state }.terminal? }
  end

  test "released? follows released_at" do
    step = workflow_steps(:tolstoy_wikidata)
    assert_not step.released?
    step.released_at = Time.current
    assert step.released?
  end

  test "keys are unique within a run" do
    run = workflow_runs(:tolstoy_author_run)
    assert_raises(ActiveRecord::RecordNotUnique) do
      run.steps.create!(key: "wikidata", queue: "author_chain", lease_seconds: 300)
    end
  end

  test "dependencies and dependent_edges are the two sides of an edge" do
    run = workflow_runs(:tolstoy_author_run)
    viaf = run.steps.create!(key: "viaf", queue: "author_chain", lease_seconds: 300)
    edge = WorkflowDependency.create!(step: viaf, prerequisite_step: workflow_steps(:tolstoy_wikidata), kind: :finish)
    assert_equal [edge], viaf.dependencies.to_a
    assert_equal [edge], workflow_steps(:tolstoy_wikidata).dependent_edges.to_a
  end
end
