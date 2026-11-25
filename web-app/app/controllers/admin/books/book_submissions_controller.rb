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

  helper_method :row_actions, :goodreads_url, :amazon_url, :book_label

  def index
    @tab = Submissions::QueueTabs.valid(params[:tab])
    @counts = Submissions::QueueTabs.counts
    @book_id = params[:book_id].to_s.match?(/\A\d{1,18}\z/) ? params[:book_id].to_i : nil
    @agent_prompt = ::Services::AgentPrompts.call(domain: :books, queue: :book_submissions)
    rows = Submissions::QueueTabs.scope(@tab).includes(*PRELOADS)
    rows = rows.where(book_id: @book_id) if @book_id
    rows = open_tab? ? rows.order(:created_at, :id) : rows.order(updated_at: :desc, id: :desc)
    @pagy, @submissions = pagy(rows, limit: PER_PAGE)
    @preview = merge_preview
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
      notice = "Dry run: would merge #{book_label(@submission.book)} into #{book_label(target)}. " \
        "The first is deleted and its readers' list entries move to the second. Nothing changed."
      finish(result, notice, **preview_params(target))
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
    message = if dry_run?
      "Dry run: would delete #{label} with #{view_context.pluralize(data[:author_ids].size, "provisional author")} " \
        "and close #{view_context.pluralize(data[:submission_ids].size, "request")} as rejected. Nothing changed."
    else
      "Rejected. #{label} is deleted."
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
  def finish(result, notice, **query)
    if result.success?
      redirect_to admin_books_book_submissions_path(tab: tab_param, **query), notice: notice
    else
      redirect_to admin_books_book_submissions_path(tab: tab_param), alert: result.errors.map { |error| error[:detail] }.to_sentence
    end
  end

  def tab_param = Submissions::QueueTabs.valid(params[:tab])

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

  # What the preview carries to the next page, so the admin confirms the book they previewed
  # with the note and sources they typed. Sources are left out when they would make the URL too long.
  def preview_params(target)
    sources_text = params[:sources].to_s
    {merge_preview: @submission.id, target_id: target.id, note: params[:note].to_s.first(Submissions::Lease::MAX_NOTE),
     sources: (sources_text unless sources_text.bytesize > 3000)}.compact
  end

  def merge_preview
    submission_id = params[:merge_preview].to_s[/\A\d{1,18}\z/]
    target_id = params[:target_id].to_s[/\A[1-9]\d{0,17}\z/]
    return unless submission_id && target_id

    target = ::Books::Book.includes(:authors).find_by(id: target_id, provisional: false)
    return unless target

    {submission_id: submission_id.to_i, target: target, note: params[:note].to_s.first(Submissions::Lease::MAX_NOTE), sources: params[:sources].to_s.first(3000)}
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
