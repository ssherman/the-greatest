# Books → Goodreads Imports (Goodreads import spec §10): every import, its
# created records, flagged decisions, parked rows and raw rows, and the
# approve, reject, rerun and per-record actions. Gates follow Repair Verdicts
# (R6): writing for approve, promote and rerun; deleting for reject, delete
# and an approve that unticks records.
class Admin::Books::GoodreadsImportsController < Admin::Books::BaseController
  SOURCES = ::Books::GoodreadsImport.sources.keys.freeze
  STATUSES = ::Books::GoodreadsImport.statuses.keys.freeze
  REVIEW_STATUSES = ::Books::GoodreadsImport.review_statuses.keys.freeze
  TABS = %w[created flagged parked rows].freeze
  RECORD_TYPES = {"Books::Book" => ::Books::Book, "Books::Author" => ::Books::Author}.freeze
  PER_PAGE = 50

  before_action :set_import, except: [:index, :bulk_approve]
  before_action :require_domain_write!, only: [:approve, :bulk_approve, :promote_record, :rerun]
  before_action :require_domain_delete!, only: [:reject, :delete_record]

  helper_method :filter_params

  def index
    @source = SOURCES.include?(params[:source]) ? params[:source] : "member"
    scope = ::Books::GoodreadsImport.where(source: @source).includes(:user)
    scope = scope.where(status: params[:status]) if STATUSES.include?(params[:status])
    scope = scope.where(review_status: params[:review_status]) if REVIEW_STATUSES.include?(params[:review_status])
    @pagy, @imports = pagy(scope.order(created_at: :desc), limit: PER_PAGE)
  end

  def show
    @tab = TABS.include?(params[:tab]) ? params[:tab] : "created"
    case @tab
    when "created"
      records = @import.records.created.where(record_type: RECORD_TYPES.keys)
      @books = ::Books::Book.where(id: records.where(record_type: "Books::Book").select(:record_id)).includes(:goodreads_editions, :authors)
      @authors = ::Books::Author.where(id: records.where(record_type: "Books::Author").select(:record_id))
    when "flagged"
      @flagged = @import.editions.joins(:match_decision).merge(::MatchDecision.needing_review).includes(:match_decision, :book)
    when "parked"
      @pagy, @rows = pagy(@import.rows.parked.order(:row_number), limit: PER_PAGE)
    when "rows"
      @pagy, @rows = pagy(@import.rows.order(:row_number), limit: PER_PAGE)
    end
  end

  def approve
    excluded = Array(params[:listed_book_ids]).map(&:to_i) - Array(params[:keep_book_ids]).map(&:to_i)
    excluded_authors = Array(params[:listed_author_ids]).map(&:to_i) - Array(params[:keep_author_ids]).map(&:to_i)
    if (excluded.any? || excluded_authors.any?) && !current_user_can_delete?
      redirect_to admin_books_goodreads_import_path(@import), alert: "Unticking records deletes them, which needs delete access."
      return
    end

    result = Services::Books::GoodreadsImports::Approve.call(import: @import, reviewer: current_user,
      exclude_book_ids: excluded, exclude_author_ids: excluded_authors)
    redirect_with_result(result, "Approved. #{result.data&.dig(:promoted_book_ids)&.size.to_i} books promoted; enrichment is queued.")
  end

  def bulk_approve
    approved = ::Books::GoodreadsImport.where(id: Array(params[:ids]).map(&:to_i)).count do |import|
      Services::Books::GoodreadsImports::Approve.call(import: import, reviewer: current_user).success?
    end
    redirect_to admin_books_goodreads_imports_path(filter_params), notice: "Approved #{approved}."
  end

  def reject
    redirect_with_result(Services::Books::GoodreadsImports::Revert.call(import: @import, reviewer: current_user),
      "Rejected. The member's imported items and reviews are removed.")
  end

  def rerun
    redirect_with_result(Services::Books::GoodreadsImports::Rerun.call(import: @import), "Queued to run again.")
  end

  def promote_record
    record = provenance_record
    result = Services::Books::GoodreadsImports::PromoteRecords.call(
      books: (record.is_a?(::Books::Book) ? [record] : []), authors: (record.is_a?(::Books::Author) ? [record] : [])
    )
    redirect_with_result(result, "Promoted.")
  end

  def delete_record
    redirect_with_result(Services::Books::GoodreadsImports::DeleteProvisional.call(import: @import, record: provenance_record), "Deleted.")
  end

  private

  def set_import
    @import = ::Books::GoodreadsImport.find(params[:id])
  end

  # Only a record this import created: an import page is not a way to delete
  # any provisional record by id.
  def provenance_record
    klass = RECORD_TYPES.fetch(params[:record_type]) { raise ActiveRecord::RecordNotFound }
    @import.records.created.find_by!(record_type: klass.name, record_id: params[:record_id])
    klass.find(params[:record_id])
  end

  def redirect_with_result(result, notice)
    if result.success?
      redirect_to admin_books_goodreads_import_path(@import), notice: notice
    else
      redirect_to admin_books_goodreads_import_path(@import), alert: result.errors.to_sentence
    end
  end

  def filter_params(overrides = {})
    request.query_parameters.slice("source", "status", "review_status").merge(overrides.stringify_keys).compact
  end
end
