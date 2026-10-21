require "test_helper"

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
class WorkflowRunTest < ActiveSupport::TestCase
  test "allows only one running run per workflow and target" do
    WorkflowRun.create!(workflow: "books.author_enrichment", definition_version: 1, enrichable: books_authors(:king), initiated_by: "test")
    assert_raises(ActiveRecord::RecordNotUnique) do
      WorkflowRun.create!(workflow: "books.author_enrichment", definition_version: 1, enrichable: books_authors(:king), initiated_by: "test")
    end
  end

  test "allows a new run once the earlier one is finished" do
    WorkflowRun.create!(workflow: "books.author_enrichment", definition_version: 1, enrichable: books_authors(:king), initiated_by: "test", status: :completed)
    assert WorkflowRun.create!(workflow: "books.author_enrichment", definition_version: 1, enrichable: books_authors(:king), initiated_by: "test").persisted?
  end

  test "can still be updated after its target is deleted" do
    run = workflow_runs(:tolstoy_author_run)
    run.update_columns(enrichable_id: 0)
    assert run.reload.update(status: :cancelled)
  end

  test "requires a workflow, target, initiator and definition version" do
    run = WorkflowRun.new
    assert_not run.valid?
    %i[workflow enrichable_type enrichable_id initiated_by definition_version].each do |attribute|
      assert_includes run.errors.attribute_names, attribute
    end
  end

  test "step finds a step by string or symbol key" do
    run = workflow_runs(:tolstoy_author_run)
    assert_equal workflow_steps(:tolstoy_wikidata), run.step("wikidata")
    assert_equal workflow_steps(:tolstoy_wikidata), run.step(:wikidata)
  end

  test "step raises for an unknown key" do
    assert_raises(ActiveRecord::RecordNotFound) { workflow_runs(:tolstoy_author_run).step(:nope) }
  end

  test "destroying a run destroys its steps" do
    run = workflow_runs(:tolstoy_author_run)
    assert_difference -> { WorkflowStep.count }, -1 do
      run.destroy!
    end
  end

  test "parent_run links a child run to the run that started it" do
    parent = workflow_runs(:tolstoy_author_run)
    child = WorkflowRun.create!(workflow: "books.book_enrichment", definition_version: 1, enrichable: books_books(:war_and_peace), initiated_by: "test", parent_run: parent)
    assert_equal parent, child.reload.parent_run
  end
end
