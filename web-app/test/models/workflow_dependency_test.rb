require "test_helper"

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
#  index_workflow_dependencies_on_prerequisite_step_id       (prerequisite_step_id)
#  index_workflow_dependencies_on_step_and_prerequisite      (step_id,prerequisite_step_id) UNIQUE
#  index_workflow_dependencies_open_on_prerequisite_step_id  (prerequisite_step_id) WHERE (satisfied_at IS NULL)
#
# Foreign Keys
#
#  fk_rails_...  (prerequisite_step_id => workflow_steps.id) ON DELETE => cascade
#  fk_rails_...  (step_id => workflow_steps.id) ON DELETE => cascade
#
class WorkflowDependencyTest < ActiveSupport::TestCase
  setup do
    @run = workflow_runs(:tolstoy_author_run)
    @wikidata = workflow_steps(:tolstoy_wikidata)
    @viaf = @run.steps.create!(key: "viaf", queue: "author_chain", lease_seconds: 300)
  end

  test "an edge between the same two steps is unique" do
    WorkflowDependency.create!(step: @viaf, prerequisite_step: @wikidata, kind: :release)
    assert_raises(ActiveRecord::RecordNotUnique) do
      WorkflowDependency.create!(step: @viaf, prerequisite_step: @wikidata, kind: :finish)
    end
  end

  test "deleting a step removes the edges on both sides" do
    WorkflowDependency.create!(step: @viaf, prerequisite_step: @wikidata, kind: :release)
    assert_difference -> { WorkflowDependency.count }, -1 do
      @wikidata.delete
    end
  end

  test "kind distinguishes release from finish edges" do
    assert_equal %w[release finish], WorkflowDependency.kinds.keys
  end
end
