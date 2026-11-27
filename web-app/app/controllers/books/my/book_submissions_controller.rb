# The reader's side of "Add a book that isn't on the site": the strip above a
# list's items (index), the submit form (create) and the strip's cancel and
# dismiss buttons. Every write is a Turbo form submission, so every non-2xx
# answer is a Turbo Stream (an HTML body would replace the whole page), and
# public layouts render no flash, so every outcome the reader must see goes
# through a stream or the strip. Never cached.
class Books::My::BookSubmissionsController < ApplicationController
  include Cacheable

  STRIP_LIMIT = 20
  WRITE_ACTIONS = %w[create cancel dismiss].freeze

  before_action :prevent_caching
  before_action :require_signed_in_for_strip!, only: :index
  before_action :require_signed_in_as_stream!, only: [:create, :cancel, :dismiss]

  # Declared after the sign-in check so an anonymous request is turned away
  # before the limiter keys on a nil user (they would all share one bucket).
  # `with:` is not optional: the default raises into an HTML error body.
  rate_limit to: 10, within: 1.minute,
    by: -> { current_user&.id },
    with: -> { render_error("You are going too fast. Wait a minute and try again", :too_many_requests) },
    store: Rails.application.config.x.rate_limit_store,
    only: [:create, :cancel, :dismiss]

  rescue_from Pundit::NotAuthorizedError, with: :not_found
  rescue_from ActiveRecord::RecordNotFound, with: :not_found
  rescue_from ActionController::InvalidAuthenticityToken, with: :invalid_token

  # GET /my/lists/:list_id/book-submissions
  # The strip. The rows are read first and announced after, so a row that
  # becomes added between the two shows as still in progress and is announced
  # by the next poll. Only the response whose conditional write won a row
  # reloads the list and marks state.
  def index
    @list = find_list
    @submissions, in_progress, read_at = read_strip(@list)
    announced = announce(@list, @submissions, read_at)
    render Books::BookSubmissions::StripComponent.new(list: @list, submissions: @submissions, reload_list: announced, in_progress: in_progress), layout: false
  end

  # POST /my/lists/:list_id/book-submissions
  def create
    list = find_list
    authorize Books::BookSubmission.new(user: current_user), :create?
    result = Services::Books::BookSubmissions::Submit.call(
      user: current_user, list: list, params: submitted_input,
      confirmed_new: params[:confirmed_new].is_a?(String) && ActiveModel::Type::Boolean.new.cast(params[:confirmed_new]) == true,
      replaces: params[:replaces]
    )
    return render_form_error(result) unless result.success?

    if result.data[:outcome] == :hits
      render turbo_stream: turbo_stream.update("book-submission-hits",
        Books::BookSubmissions::HitsComponent.new(list: list, books: result.data[:books], input: submitted_input, replaces: params[:replaces]))
    else
      render turbo_stream: [
        turbo_stream.update("book-submission-errors", ""),
        turbo_stream.update("book-submission-hits", ""),
        strip_stream(list)
      ], status: (result.data[:outcome] == :created) ? :created : :ok
    end
  end

  # POST /my/book-submissions/:id/cancel
  def cancel
    change(:cancel?) { |submission| Services::Books::BookSubmissions::Cancel.call(user: current_user, id: submission.id) }
  end

  # POST /my/book-submissions/:id/dismiss
  def dismiss
    change(:dismiss?) { |submission| Services::Books::BookSubmissions::Dismiss.call(user: current_user, id: submission.id) }
  end

  private

  def change(permission)
    submission = current_user.book_submissions.origin_reader.find(params[:id])
    authorize submission, permission
    result = yield submission
    list = submission.user_list_id && owned_books_lists.find_by(id: submission.user_list_id)
    unless result.success?
      # The button the reader pressed is stale, so the answer replaces the strip too.
      streams = [error_stream(result.errors.to_sentence)]
      streams << strip_stream(list) if list
      return render turbo_stream: streams, status: :unprocessable_entity
    end

    render turbo_stream: list ? strip_stream(list) : []
  end

  def owned_books_lists
    current_user.user_lists.where(type: "Books::UserList")
  end

  def find_list
    owned_books_lists.find(params[:list_id])
  end

  # What the strip shows: every open row, and the finished ones the reader has
  # not dismissed, except a cancelled one that was not rejected. Newest first.
  def strip_submissions(list)
    base = Books::BookSubmission.origin_reader.visible.where(user_id: current_user.id, user_list_id: list.id)
    base.where.not(status: :cancelled).or(base.where(review_status: :rejected))
      .includes(:book).order(created_at: :desc, id: :desc).limit(STRIP_LIMIT)
  end

  # Rows first, then the announcement (see index). in_progress covers every
  # undismissed row of the list, not only the 20 shown. A shown row that is in
  # progress also keeps the strip polling (the component checks its own rows),
  # even if it flipped to added after this query.
  def read_strip(list)
    read_at = Time.current
    rows = strip_submissions(list).to_a
    in_progress = Books::BookSubmission.origin_reader.visible.where(user_id: current_user.id, user_list_id: list.id, status: Books::BookSubmission::IN_PROGRESS_STATUSES).exists?
    [rows, in_progress, read_at]
  end

  def strip_stream(list)
    rows, in_progress, read_at = read_strip(list)
    announced = announce(list, rows, read_at)
    turbo_stream.replace("book_submissions",
      Books::BookSubmissions::StripComponent.new(list: list, submissions: rows, reload_list: announced, in_progress: in_progress))
  end

  # Every response that renders the strip for the owner announces here, after
  # it has read its rows. One conditional write over the list's added rows
  # nobody has announced yet: the ones this response shows as added, and the
  # ones it does not show (dismissed, or behind the 20 newest) that existed
  # before it read. A row this response shows in any other status is left for
  # the next poll, since the reader has not seen it added. The write is
  # conditional, so two responses at once announce a row once and only the
  # winner reloads the list and marks user state. A HEAD or prefetch request
  # must not take the announcement away from the reader's real request.
  def announce(list, rows, read_at)
    return false if request.head? || prefetch?

    shown = rows.map(&:id)
    shown_added = rows.select(&:added?).map(&:id)
    pending = Books::BookSubmission.origin_reader.where(user_id: current_user.id, user_list_id: list.id, status: :added, announced_at: nil)
    unshown = pending.where.not(id: shown).where(created_at: ...read_at)
    pending = pending.where(id: shown_added).or(unshown)
    changed = pending.update_all(announced_at: Time.current).positive?
    mark_user_state_changed if changed
    changed
  end

  def prefetch?
    %w[Purpose Sec-Purpose X-Sec-Purpose X-Purpose X-Moz].any? { |name| request.headers[name].to_s.match?(/prefetch|preview/i) }
  end

  # The form's fields, or an empty hash for anything that is not a form
  # (a string or an array in its place must not raise).
  def submitted_input
    raw = params[:book_submission]
    raw.is_a?(ActionController::Parameters) ? raw.to_unsafe_h : {}
  end

  # The strip is a lazily loaded Turbo Frame: a redirect to the home page, or
  # the not-found page, would be rendered inside it. A frame request is
  # answered with the empty frame and the status, and the poller stops on it.
  def require_signed_in_for_strip!
    return render_empty_strip(:unauthorized) if strip_frame_request? && !current_user

    require_signed_in!
  end

  def strip_frame_request?
    action_name == "index" && request.headers["Turbo-Frame"] == "book_submissions"
  end

  def render_empty_strip(status)
    prevent_caching
    render html: helpers.turbo_frame_tag("book_submissions", target: "_top"), layout: false, status: status
  end

  def require_signed_in_as_stream!
    render_error("Sign in again to continue", :unauthorized) unless current_user
  end

  def not_found
    return render_empty_strip(:not_found) if strip_frame_request?
    return render_not_found if action_name == "index"

    render_error("That list or request no longer exists. Reload the page", :not_found)
  end

  def invalid_token
    render_error("Your session expired. Reload the page and try again", :unprocessable_entity)
  end

  # The dialog's error line for a refused form; a toast for everything else,
  # a list deleted under the request included.
  def render_form_error(result)
    return not_found if result.data && result.data[:reason] == :gone

    status = (result.data && result.data[:reason] == :limit) ? :too_many_requests : :unprocessable_entity
    render turbo_stream: turbo_stream.update("book-submission-errors", ERB::Util.html_escape(result.errors.to_sentence)), status: status
  end

  def render_error(message, status)
    render turbo_stream: error_stream(message), status: status
  end

  def error_stream(message)
    turbo_stream.append("toast-region", Toast::MessageComponent.new(message: message, type: :error))
  end
end
