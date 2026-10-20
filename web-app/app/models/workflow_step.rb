# One unit of work inside a WorkflowRun. Its state, lease and retry counters
# live here so the coordinator can decide what runs next without asking Sidekiq.
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
#  index_workflow_steps_on_workflow_run_id             (workflow_run_id)
#  index_workflow_steps_on_workflow_run_id_and_key     (workflow_run_id,key) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (workflow_run_id => workflow_runs.id)
#
class WorkflowStep < ApplicationRecord
  TERMINAL_STATES = %w[succeeded skipped failed].freeze

  belongs_to :run, class_name: "WorkflowRun", foreign_key: :workflow_run_id, inverse_of: :steps

  has_many :dependencies, class_name: "WorkflowDependency", foreign_key: :step_id, dependent: :delete_all, inverse_of: :step
  has_many :dependent_edges, class_name: "WorkflowDependency", foreign_key: :prerequisite_step_id, dependent: :delete_all, inverse_of: :prerequisite_step

  enum :state, {blocked: 0, ready: 1, running: 2, waiting: 3, succeeded: 4, skipped: 5, failed: 6}

  validates :key, :queue, presence: true

  def terminal?
    TERMINAL_STATES.include?(state)
  end

  # True once dependents may proceed. Set on every terminal state, and earlier
  # for a step that hands off while it keeps working.
  def released?
    released_at.present?
  end
end
