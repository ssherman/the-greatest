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

  helper_method :row_actions, :goodreads_url, :amazon_url, :book_label, :return_params

  def index
    load_page
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
      target = ::Books::Book.includes(:authors).find(result.data[:target_id])
      render_preview("Dry run: would merge #{book_label(@submission.book)} into #{book_label(target)}. " \
        "The first is deleted and its readers' list entries move to the second. Nothing changed.", target: target)
    else
      warnings = Array(result.data[:warnings]).map { |warning| warning.is_a?(Hash) ? (warning[:detail] || warning["detail"]).to_s : warning.to_s }.compact_blank
      finish(result, "Merged into #{book_label(result.data[:target])}.#{" Warnings: #{warnings.join(" ")}" if warnings.any?}")
    end
  end

  def reject
    label = book_label(@submission.book)
    result = Submissions::Reject.call(submission: @submission, user: current_user, via: VIA, note: params[:note].to_s,
      sources: sources, dry_run: dry_run?)
    return finish(result, nil) unless result.success?

    data = result.data
    if dry_run?
      render_preview("Dry run: would delete #{label} with #{view_context.pluralize(data[:author_ids].size, "provisional author")} " \
        "and close #{view_context.pluralize(data[:submission_ids].size, "request")} as rejected. Nothing changed.")
    else
      finish(result, "Rejected. #{label} is deleted.")
    end
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
    redirect_to admin_books_book_submissions_path(**return_params), alert: "That submission no longer exists." unless @submission
  end

  # Every action comes back to the page the admin was on (tab, page and book filter), so the queue
  # carries on where it was. The notice says where a settled row went, so it is not lost.
  def finish(result, notice)
    if result.success?
      redirect_to admin_books_book_submissions_path(**return_params), notice: "#{notice}#{moved_note}"
    else
      redirect_to admin_books_book_submissions_path(**return_params), alert: result.errors.map { |error| error[:detail] }.to_sentence
    end
  end

  def moved_note
    row = ::Books::BookSubmission.find_by(id: @submission.id)
    tab = row && (row.review_status if %w[approved merged rejected needs_human].include?(row.review_status))
    tab ? " It is now under the #{Submissions::QueueTabs::LABELS.fetch(tab)} tab." : ""
  end

  # A preview is answered in place, 422 as Turbo wants for a form that does not redirect, with the
  # one submission shown and the form filled in from what was posted: the note, sources and target
  # never travel in a URL or a cookie, and nothing is dropped. Back to the queue keeps tab, page and filter.
  def render_preview(notice, target: nil)
    load_page
    @prefill = {submission_id: @submission.id, note: params[:note].to_s, sources: params[:sources].to_s, target: target}
    @submissions = ::Books::BookSubmission.where(id: @submission.id).includes(*PRELOADS).to_a
    @preview_only = true
    flash.now[:notice] = notice
    render :index, status: :unprocessable_entity
  end

  def load_page
    @tab = return_params[:tab]
    @book_id = return_params[:book_id]
    @counts = Submissions::QueueTabs.counts
    @agent_prompt = ::Services::AgentPrompts.call(domain: :books, queue: :book_submissions)
  end

  # Where to come back to: the tab (one of ours), the page and the book filter (digits only).
  def return_params
    @return_params ||= {
      tab: Submissions::QueueTabs.valid(params[:tab]),
      page: params[:page].to_s[/\A[1-9]\d{0,6}\z/]&.to_i,
      book_id: params[:book_id].to_s[/\A\d{1,18}\z/]&.to_i
    }.compact
  end

  def open_tab? = %w[needs_review needs_details].include?(@tab)

  # Only an explicit "false" is the real thing. A missing or odd value (a hash, an array) is a preview.
  def dry_run? = params[:dry_run] != "false"

  def sources = params[:sources].to_s.lines.map(&:strip).reject(&:blank?)

  # The form's three identifier fields, blank ones left out. An ISBN goes in as isbn13 and the
  # service reads both lengths from it.
  def identifiers
    {"isbn13" => params[:isbn], "asin" => params[:asin], "goodreads_id" => params[:goodreads_id]}
      .transform_values { |value| value.to_s.strip }.reject { |_, value| value.empty? }
  end

  # A book as the admin must see it to be sure which one it is.
  def book_label(book)
    return "(unknown)" unless book

    authors = book.authors.map(&:name).join(", ").presence || "unknown author"
    "\"#{book.title.to_s.truncate(80)}\" by #{authors.truncate(80)} (#{[book.first_published_year, "##{book.id}"].compact.join(", ")})"
  end

  def row_actions(row) = Submissions::RowActions.for(row)

  # Links are built by us from the parsed id, never from what the reader pasted.
  def goodreads_url(row)
    "https://www.goodreads.com/book/show/#{row.goodreads_book_id}" if row.goodreads_book_id
  end

  def amazon_url(row)
    "https://www.amazon.com/dp/#{row.asin}" if row.asin.to_s.match?(Submissions::SupplyDetails::ASIN)
  end
end
