# The Goodreads replay's findings (Goodreads import spec §12.7). Approving
# never applies: books:goodreads_replay:apply does, in the spec's order, when
# config.x.goodreads_replay.auto_apply is on. decided_by stays the finder's
# (rule or ai); the reviewer is decided_by_user_id and reviewed_at.
class Admin::Books::RepairVerdictsController < Admin::Books::BaseController
  KINDS = ::Books::RepairVerdict.kinds.keys.freeze
  STATUSES = ::Books::RepairVerdict.statuses.keys.freeze
  DECIDED_BY = ::Books::RepairVerdict.decided_bies.keys.freeze
  CONFIDENCES = ::Books::RepairVerdict.confidences.keys.freeze
  FILTER_KEYS = %w[kind status decided_by confidence].freeze
  PER_PAGE = 50

  before_action :set_verdict, only: [:show, :approve, :reject]
  # An approved merge destroys a row on the next apply, so approving takes the
  # delete gate, as the match-decision reject does.
  before_action :require_domain_delete!, only: [:approve, :bulk_approve]
  before_action :require_domain_write!, only: [:reject]

  helper_method :filter_params

  def index
    @status = STATUSES.include?(params[:status]) ? params[:status] : "proposed"
    scope = filtered_scope
    @counts = scope.group(:status).count
    @pagy, @verdicts = pagy(scope.where(status: @status).newest_first, limit: PER_PAGE)
  end

  def show
    @source_rows = source_rows
    @books = ::Books::Book.where(id: @verdict.book_ids).index_by(&:id)
    @authors = ::Books::Author.where(id: @verdict.author_ids).index_by(&:id)
    @decision = ::MatchDecision.find_by(id: @verdict.payload["match_decision_id"])
  end

  def approve
    unless @verdict.proposed?
      redirect_to admin_books_repair_verdict_path(@verdict), alert: "This verdict is already #{@verdict.status}."
      return
    end

    review!(@verdict, :approved)
    redirect_to admin_books_repair_verdict_path(@verdict), notice: "Approved. The next books:goodreads_replay:apply applies it."
  end

  def reject
    if @verdict.rejected?
      redirect_to admin_books_repair_verdict_path(@verdict), alert: "This verdict is already rejected."
      return
    end
    # An applied merge or relink cannot be taken back here, but rejecting it
    # still matters: every replay pass re-applies approved verdicts after a
    # books re-migration, and a rejected one is never applied again.
    notice = "Rejected."
    if @verdict.applied_at.present?
      if @verdict.mark_provisional?
        revert_provisional
      else
        notice = "Rejected. What it already changed is not undone; it will not be applied again after a books re-migration."
      end
    end

    review!(@verdict, :rejected)
    redirect_to admin_books_repair_verdict_path(@verdict), notice: notice
  end

  def bulk_approve
    scope = (params[:all_matching] == "1") ? filtered_scope : ::Books::RepairVerdict.where(id: Array(params[:ids]).map(&:to_i))
    now = Time.current
    count = scope.proposed.update_all(status: ::Books::RepairVerdict.statuses[:approved], decided_by_user_id: current_user.id,
      reviewed_at: now, updated_at: now)
    redirect_to admin_books_repair_verdicts_path(filter_params), notice: "Approved #{count}."
  end

  private

  def set_verdict
    @verdict = ::Books::RepairVerdict.find(params[:id])
  end

  def filtered_scope
    scope = ::Books::RepairVerdict.all
    scope = scope.where(kind: params[:kind]) if KINDS.include?(params[:kind])
    scope = scope.where(decided_by: params[:decided_by]) if DECIDED_BY.include?(params[:decided_by])
    scope = scope.where(confidence: params[:confidence]) if CONFIDENCES.include?(params[:confidence])
    scope
  end

  def review!(verdict, status)
    verdict.update!(status: status, decided_by_user_id: current_user.id, reviewed_at: Time.current)
  end

  def revert_provisional
    result = ::Services::Books::GoodreadsReplay::Apply::MarkProvisional.revert(verdict: @verdict)
    ::Services::RankingConfigurations::RequestRefresh.call_for_ids(result.data[:ranking_configuration_ids], delay: 5.minutes)
    @verdict.update!(applied_at: nil)
  end

  # The import rows the finding came from: [legacy import id, row number] pairs.
  def source_rows
    pairs = Array(@verdict.payload["rows"])
    return [] if pairs.empty?

    imports = ::Books::GoodreadsImport.where(legacy_import_id: pairs.map(&:first)).index_by(&:legacy_import_id)
    pairs.filter_map { |legacy_id, row_number| imports[legacy_id]&.rows&.find_by(row_number: row_number) }
  end

  def filter_params(overrides = {})
    request.query_parameters.slice(*FILTER_KEYS).merge(overrides.stringify_keys).compact
  end
end
