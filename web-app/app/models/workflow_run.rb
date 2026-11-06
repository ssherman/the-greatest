# One execution of a workflow (a fixed set of steps) against one record. The
# row is the source of truth for coordination; Sidekiq only executes steps.
#
# The target is optional because it can be deleted while the run is still on
# record (a merged book, a removed author). The type and id are validated
# instead, so a run for a deleted target can still be updated and cancelled.
# == Schema Information
#
# Table name: workflow_runs
#
#  id                 :bigint           not null, primary key
#  definition_version :integer          not null
#  enrichable_type    :string           not null
#  error_summary      :text
#  finished_at        :datetime
#  initiated_by       :string           not null
#  options            :jsonb            not null
#  started_at         :datetime
#  status             :integer          default("running"), not null
#  workflow           :string           not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  enrichable_id      :bigint           not null
#  parent_run_id      :bigint
#
# Indexes
#
#  index_workflow_runs_on_enrichable     (enrichable_type,enrichable_id)
#  index_workflow_runs_on_parent_run_id  (parent_run_id)
#  index_workflow_runs_on_status         (status)
#  index_workflow_runs_one_active        (workflow,enrichable_type,enrichable_id) UNIQUE WHERE (status = 0)
#
# Foreign Keys
#
#  fk_rails_...  (parent_run_id => workflow_runs.id) ON DELETE => nullify
#
class WorkflowRun < ApplicationRecord
  belongs_to :enrichable, polymorphic: true, optional: true
  belongs_to :parent_run, class_name: "WorkflowRun", optional: true

  has_many :steps, class_name: "WorkflowStep", dependent: :destroy, inverse_of: :run

  enum :status, {running: 0, completed: 1, completed_with_failures: 2, cancelled: 3}

  validates :workflow, :initiated_by, :enrichable_type, :enrichable_id, presence: true
  validates :definition_version, presence: true

  # The step with this key. Raises when the run has no such step.
  def step(key)
    steps.find_by!(key: key.to_s)
  end
end
