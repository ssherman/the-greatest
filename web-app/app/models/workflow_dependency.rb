# An edge: `step` waits on `prerequisite_step`, which may belong to another run.
# A `release` edge is satisfied when the prerequisite is released; a `finish`
# edge only when it is terminal.
# == Schema Information
#
# Table name: workflow_dependencies
#
#  id                   :bigint           not null, primary key
#  kind                 :integer          default("release"), not null
#  satisfied_at         :datetime
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  prerequisite_step_id :bigint           not null
#  step_id              :bigint           not null
#
# Indexes
#
#  index_workflow_dependencies_on_prerequisite_step_id         (prerequisite_step_id)
#  index_workflow_dependencies_on_step_and_prerequisite        (step_id,prerequisite_step_id) UNIQUE
#  index_workflow_dependencies_open_on_prerequisite_step_id    (prerequisite_step_id) WHERE (satisfied_at IS NULL)
#
# Foreign Keys
#
#  fk_rails_...  (prerequisite_step_id => workflow_steps.id) ON DELETE => cascade
#  fk_rails_...  (step_id => workflow_steps.id) ON DELETE => cascade
#
class WorkflowDependency < ApplicationRecord
  belongs_to :step, class_name: "WorkflowStep", inverse_of: :dependencies
  belongs_to :prerequisite_step, class_name: "WorkflowStep", inverse_of: :dependent_edges

  enum :kind, {release: 0, finish: 1}
end
