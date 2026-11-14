# The Goodreads replay's findings (Goodreads import spec §12.7). Approving
# never applies: books:goodreads_replay:apply does, in the spec's order, when
# config.x.goodreads_replay.auto_apply is on. decided_by stays the finder's
# (rule or ai); the reviewer is decided_by_user_id and reviewed_at.
class Admin::Books::RepairVerdictsController < Admin::Books::BaseController
  FILTER_KEYS = %w[kind status decided_by confidence guess].freeze
  PER_PAGE = 50
  BULK_BATCH = 1000
  VIA = "admin_ui"

  before_action :set_verdict, only: [:show, :approve, :reject, :correct]
  # An approved merge destroys a row on the next apply, so approving takes the
  # delete gate, as the match-decision reject does.
  before_action :require_domain_delete!, only: [:approve, :bulk_approve]
  before_action :require_domain_write!, only: [:reject, :correct]

  helper_method :filter_params

  def index
    @status = ::Services::Books::RepairVerdicts::Filter::STATUSES.include?(params[:status]) ? params[:status] : "proposed"
    scope = filtered_scope
    @counts = scope.group(:status).count
    @pagy, @verdicts = pagy(scope.where(status: @status).newest_first, limit: PER_PAGE)
    load_row_context
    @agent_prompt = ::Services::AgentPrompts.call(domain: :books, queue: :repair_verdicts)
  end

  def show
    @source_rows = source_rows
    @books = ::Books::Book.where(id: @verdict.book_ids).index_by(&:id)
    @authors = ::Books::Author.where(id: @verdict.author_ids).index_by(&:id)
    @decision = ::MatchDecision.find_by(id: @verdict.payload["match_decision_id"])
  end

  def approve
    result = ::Services::Books::RepairVerdicts::Review.approve(verdict: @verdict, user: current_user, via: VIA)
    if result.success?
      redirect_to admin_books_repair_verdict_path(@verdict), notice: "Approved. The next books:goodreads_replay:apply applies it."
    else
      redirect_to admin_books_repair_verdict_path(@verdict), alert: result.errors.join(", ")
    end
  end

  def reject
    result = ::Services::Books::RepairVerdicts::Review.reject(verdict: @verdict, user: current_user, via: VIA)
    unless result.success?
      redirect_to admin_books_repair_verdict_path(@verdict), alert: result.errors.join(", ")
      return
    end

    notice = "Rejected."
    if result.data[:applied] && !result.data[:reverted]
      notice = "Rejected. What it already changed is not undone; it will not be applied again after a books re-migration."
    end
    redirect_to admin_books_repair_verdict_path(@verdict), notice: notice
  end

  # A re-import match the AI got wrong: the right book, or create a new one (Services::Books::GoodreadsReimport::
  # CorrectMatch). Rejecting alone strands the match's readers.
  def correct
    result = ::Services::Books::GoodreadsReimport::CorrectMatch.call(verdict: @verdict, user: current_user,
      book_id: params[:book_id], create: params[:create], via: VIA)
    if result.success?
      redirect_to admin_books_repair_verdict_path(@verdict), notice: "Corrected and approved. The next books:goodreads_reimport:apply applies it."
    else
      redirect_to admin_books_repair_verdict_path(@verdict), alert: result.errors.join(", ")
    end
  end

  def bulk_approve
    scope = (params[:all_matching] == "1") ? filtered_scope.proposed : ::Books::RepairVerdict.where(id: Array(params[:ids]).map(&:to_i))
    count = scope.pluck(:id).each_slice(BULK_BATCH).sum do |ids|
      ::Services::Books::RepairVerdicts::Review.bulk_approve(ids: ids, user: current_user, via: VIA).data[:approved_ids].size
    end
    redirect_to admin_books_repair_verdicts_path(filter_params), notice: "Approved #{count}."
  end

  private

  # What the page's verdicts point at, loaded once for all rows (the row
  # component queries nothing): books with authors, authors, and the number
  # of list items on each merge target.
  def load_row_context
    book_ids = @verdicts.flat_map(&:book_ids).uniq
    @books = ::Books::Book.where(id: book_ids).includes(:authors).index_by(&:id)
    @authors = ::Books::Author.where(id: @verdicts.flat_map(&:author_ids).uniq).index_by(&:id)
    target_ids = @verdicts.select(&:merge_books?).filter_map { |verdict| verdict.payload["target_id"] }.uniq
    @list_counts = ::ListItem.where(listable_type: "Books::Book", listable_id: target_ids).group(:listable_id).count
  end

  def set_verdict
    @verdict = ::Books::RepairVerdict.find(params[:id])
  end

  def filtered_scope
    ::Services::Books::RepairVerdicts::Filter.call(kind: params[:kind], decided_by: params[:decided_by],
      confidence: params[:confidence], guess: params[:guess])
  end

  # The import rows the finding came from: [legacy import id, row number] pairs.
  def source_rows = ::Services::Books::RepairVerdicts::SourceRows.call(@verdict)

  def filter_params(overrides = {})
    request.query_parameters.slice(*FILTER_KEYS).merge(overrides.stringify_keys).compact
  end
end
