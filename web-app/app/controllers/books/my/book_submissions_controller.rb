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
  before_action :require_signed_in!, only: :index
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
  # The strip. A row that is newly added is announced here, once: only the
  # response whose conditional write won it reloads the list and marks state.
  def index
    @list = find_list
    announced = announce(@list)
    @submissions = strip_submissions(@list).to_a
    render Books::BookSubmissions::StripComponent.new(list: @list, submissions: @submissions, reload_list: announced), layout: false
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
    submission = current_user.book_submissions.find(params[:id])
    authorize submission, permission
    result = yield submission
    return render_error(result.errors.to_sentence, :unprocessable_entity) unless result.success?

    list = submission.user_list_id && owned_books_lists.find_by(id: submission.user_list_id)
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
    base = Books::BookSubmission.visible.where(user_id: current_user.id, user_list_id: list.id)
    base.where.not(status: :cancelled).or(base.where(review_status: :rejected))
      .order(created_at: :desc, id: :desc).limit(STRIP_LIMIT)
  end

  def strip_stream(list)
    announced = announce(list)
    turbo_stream.replace("book_submissions",
      Books::BookSubmissions::StripComponent.new(list: list, submissions: strip_submissions(list).to_a, reload_list: announced))
  end

  # Every response that renders the strip for the owner announces here, before
  # it reads the rows. One conditional write over the list's added rows nobody
  # has announced yet, whatever the strip shows (dismissed rows and rows behind
  # the 20 newest included), so two responses at once announce a row once and
  # only the winner reloads the list and marks user state. A HEAD or prefetch
  # request must not take the announcement away from the reader's real request.
  def announce(list)
    return false if request.head? || prefetch?

    changed = Books::BookSubmission.where(user_id: current_user.id, user_list_id: list.id, status: :added, announced_at: nil)
      .update_all(announced_at: Time.current).positive?
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

  def require_signed_in_as_stream!
    render_error("Sign in again to continue", :unauthorized) unless current_user
  end

  def not_found
    return render_not_found if action_name == "index"

    render_error("That list or request no longer exists. Reload the page", :not_found)
  end

  def invalid_token
    render_error("Your session expired. Reload the page and try again", :unprocessable_entity)
  end

  # The dialog's error line for a refused form; a toast for everything else.
  def render_form_error(result)
    status = (result.data && result.data[:reason] == :limit) ? :too_many_requests : :unprocessable_entity
    render turbo_stream: turbo_stream.update("book-submission-errors", ERB::Util.html_escape(result.errors.to_sentence)), status: status
  end

  def render_error(message, status)
    toast = Toast::MessageComponent.new(message: message, type: :error)
    render turbo_stream: turbo_stream.append("toast-region", toast), status: status
  end
end
