# The "Enrichment runs" frame on a book's or author's admin page: the newest
# runs against that record, with each step's state and what it is waiting on.
class Admin::Books::WorkflowRunsController < Admin::Books::BaseController
  before_action :set_item
  before_action :authorize_item

  RUN_LIMIT = 20

  def index
    @runs = WorkflowRun.where(enrichable: @item)
      .includes(steps: {dependencies: {prerequisite_step: :run}})
      .order(created_at: :desc, id: :desc).limit(RUN_LIMIT)
    @ledger_by_step = ledger_rows_by_step(@runs)
    @targets = prerequisite_targets(@runs)
    render layout: false
  end

  private

  def domain_auth_parent
    @domain_auth_parent ||= Admin::DomainRouting.parent_from_params(params, domain: current_domain)
  end

  def set_item
    @item = domain_auth_parent
    raise ActiveRecord::RecordNotFound, "No book or author given" unless @item.is_a?(::Books::Book) || @item.is_a?(::Books::Author)
  end

  # The same policy call the parent's own show page makes.
  def authorize_item
    authorize @item, :show?
  end

  # One query for every step's ledger rows, grouped by step.
  def ledger_rows_by_step(runs)
    step_ids = runs.flat_map { |run| run.steps.map(&:id) }
    Enrichment.where(workflow_step_id: step_ids).order(:created_at, :id).group_by(&:workflow_step_id)
  end

  # The record each unsatisfied prerequisite's run belongs to, loaded with one
  # query per type, so the view can link to it without a query per edge.
  def prerequisite_targets(runs)
    prerequisite_runs = runs.flat_map(&:steps).flat_map(&:dependencies)
      .reject(&:satisfied_at).map { |edge| edge.prerequisite_step.run }.uniq
    prerequisite_runs.group_by(&:enrichable_type).flat_map do |type, group|
      klass = type.safe_constantize
      next [] unless klass
      klass.where(id: group.map(&:enrichable_id)).map { |record| [[type, record.id], record] }
    end.to_h
  end
end
