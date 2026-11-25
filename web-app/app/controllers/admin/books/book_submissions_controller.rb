# The books readers asked for that the catalogue lacked: the review queue, with the admin's own
# approve, merge, reject, supply-details and retry. Every rule lives in
# Services::Books::BookSubmissions, shared with the agents' API; this controller parses the form,
# calls the service and turns its Result into a flash. A refusal (a row another reviewer settled
# meanwhile, a bad target) is an alert, never an error.
#
# Merge and reject run outside any transaction or lock of ours: the services take their own locks
# in the order that keeps them clear of the lookup jobs.
class Admin::Books::BookSubmissionsController < Admin::Books::BaseController
  PER_PAGE = 50
  VIA = "admin_ui"
  Submissions = ::Services::Books::BookSubmissions
  PRELOADS = [:user, :user_list, :reviewed_by, :match_decision, {book: [:authors, :submissions]}].freeze

  # Approving, merging and rejecting settle or destroy a book, so they take the delete gate.
  before_action :require_domain_delete!, only: [:approve, :merge, :reject]
  before_action :require_domain_write!, only: [:supply_details, :retry]
  before_action :set_submission, only: [:approve, :merge, :reject, :supply_details, :retry]

  helper_method :row_actions, :goodreads_url, :amazon_url

  def index
    @tab = Submissions::QueueTabs.valid(params[:tab])
    @counts = Submissions::QueueTabs.counts
    @book_id = params[:book_id].to_s.match?(/\A\d{1,18}\z/) ? params[:book_id].to_i : nil
    @agent_prompt = ::Services::AgentPrompts.call(domain: :books, queue: :book_submissions)
    rows = Submissions::QueueTabs.scope(@tab).includes(*PRELOADS)
    rows = rows.where(book_id: @book_id) if @book_id
    rows = open_tab? ? rows.order(:created_at, :id) : rows.order(updated_at: :desc, id: :desc)
    @pagy, @submissions = pagy(rows, limit: PER_PAGE)
  end

  def approve
    result = Submissions::Approve.call(submission: @submission, user: current_user, via: VIA, note: params[:note].to_s, sources: sources)
    finish(result, "Approved. The book is public.")
  end

  def merge
    target_id = params[:target_id].to_s.strip
    result = Submissions::Merge.call(submission: @submission, target_id: target_id, user: current_user, via: VIA,
      note: params[:note].to_s, sources: sources, dry_run: dry_run?)
    return finish(result, nil) unless result.success?

    if dry_run?
      finish(result, "Dry run: would merge \"#{title_of(@submission.book)}\" into \"#{title_of(::Books::Book.find_by(id: result.data[:target_id]))}\". " \
        "The first is deleted and its readers' list entries move to the second. Nothing changed.")
    else
      warnings = Array(result.data[:warnings]).presence
      finish(result, "Merged into \"#{title_of(result.data[:target])}\".#{" Warnings: #{warnings.to_sentence}" if warnings}")
    end
  end

  def reject
    book = @submission.book
    result = Submissions::Reject.call(submission: @submission, user: current_user, via: VIA, note: params[:note].to_s,
      sources: sources, dry_run: dry_run?)
    return finish(result, nil) unless result.success?

    data = result.data
    message = if dry_run?
      "Dry run: would delete \"#{title_of(book)}\" with #{view_context.pluralize(data[:author_ids].size, "provisional author")} " \
        "and close #{view_context.pluralize(data[:submission_ids].size, "request")} as rejected. Nothing changed."
    else
      "Rejected. \"#{title_of(book)}\" is deleted."
    end
    finish(result, message)
  end

  def supply_details
    result = Submissions::SupplyDetails.call(submission: @submission, title: params[:title].to_s,
      author_names: params[:authors].to_s.lines.map(&:strip).reject(&:blank?), identifiers: identifiers,
      user: current_user, via: VIA, note: params[:note].to_s)
    finish(result, "Details supplied. The lookup runs again.")
  end

  def retry
    result = Submissions::Retry.call(submission: @submission, user: current_user)
    finish(result, "Queued again.")
  end

  private

  def set_submission
    @submission = ::Books::BookSubmission.find_by(id: params[:id])
    redirect_to admin_books_book_submissions_path(tab: tab_param), alert: "That submission no longer exists." unless @submission
  end

  # The redirect keeps the tab the admin was on; a tab that is not one of ours is the default.
  def finish(result, notice)
    if result.success?
      redirect_to admin_books_book_submissions_path(tab: tab_param), notice: notice
    else
      redirect_to admin_books_book_submissions_path(tab: tab_param), alert: result.errors.map { |error| error[:detail] }.to_sentence
    end
  end

  def tab_param = Submissions::QueueTabs.valid(params[:tab])

  def open_tab? = %w[needs_review needs_details].include?(@tab)

  def dry_run? = params[:dry_run] == "true"

  def sources = params[:sources].to_s.lines.map(&:strip).reject(&:blank?)

  # The form's three identifier fields, blank ones left out. An ISBN goes in as isbn13 and the
  # service reads both lengths from it.
  def identifiers
    {"isbn13" => params[:isbn], "asin" => params[:asin], "goodreads_id" => params[:goodreads_id]}
      .transform_values { |value| value.to_s.strip }.reject { |_, value| value.empty? }
  end

  def title_of(book) = book ? book.title.to_s.truncate(80) : "(unknown)"

  def row_actions(row) = Submissions::RowActions.for(row)

  # Links are built by us from the parsed id, never from what the reader pasted.
  def goodreads_url(row)
    "https://www.goodreads.com/book/show/#{row.goodreads_book_id}" if row.goodreads_book_id
  end

  def amazon_url(row)
    "https://www.amazon.com/dp/#{row.asin}" if row.asin.to_s.match?(Submissions::SupplyDetails::ASIN)
  end
end
