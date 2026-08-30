# Public list submission, for every domain. Modelled on CorrectionsController --
# read that one alongside this; the reasoning recorded in its comments applies
# here almost line for line.
class ListSubmissionsController < ApplicationController
  include Cacheable
  include VisitorIp

  layout :domain_layout

  # The form page is edge-cached, so its <meta name="csrf-token"> belongs to
  # whoever populated the cache. The Stimulus controller fetches a real token from
  # /form_token on first interaction -- but if that fetch never happened (JS off,
  # blocked, slow), null_session accepts the write as ANONYMOUS rather than
  # showing the submitter a 422 they cannot act on.
  #
  # CSRF exists to stop a forged request riding a victim's ambient session
  # authority; null_session removes exactly that authority. What lands is a
  # submission the attacker could have posted directly, and it is moderated
  # before it is visible anywhere.
  protect_from_forgery with: :null_session, only: [:create]

  before_action :set_submittable_types
  before_action :set_list_class, only: [:create]
  before_action :cache_for_show_page, only: [:new, :thanks]
  before_action :prevent_caching, only: [:create]

  # Two buckets, sized from the legacy corpus rather than guessed. One
  # contributor submitted 25 lists in a single day and 8 separate days exceeded
  # 5, so a flat low cap would reject exactly the people who made this feature
  # worth porting -- 152 of their 209 submissions are live on the site today.
  #
  # Anonymous submitters share an IP bucket and cannot be identified, so they get
  # a tighter cap. Nothing an anonymous flood produces is published; it costs
  # triage time.
  #
  # by: goes through visitor_ip, NEVER request.remote_ip -- in production that is
  # the Cloudflare edge IP, so keying on it puts every visitor in one bucket and
  # throttles the whole site.
  #
  # with: renders rather than redirects: the redirect target is edge-cached, so a
  # flash set there is never read. Rails' default raise renders an HTML error body.
  #
  # Declared AFTER set_submittable_types, and that ordering is load-bearing:
  # filters run in declaration order and rate_limit installs its own
  # before_action, so @submittable_types is set when the with: lambda re-renders.
  SIGNED_IN_RATE = 30
  ANONYMOUS_RATE = 10
  RATE_WINDOW = 1.hour

  rate_limit to: SIGNED_IN_RATE, within: RATE_WINDOW,
    by: -> { current_user.id },
    with: -> { render_rate_limited },
    store: Rails.application.config.x.rate_limit_store,
    name: "list-submissions-create-signed-in",
    only: [:create],
    if: -> { current_user.present? }

  rate_limit to: ANONYMOUS_RATE, within: RATE_WINDOW,
    by: -> { visitor_ip },
    with: -> { render_rate_limited },
    store: Rails.application.config.x.rate_limit_store,
    name: "list-submissions-create-anonymous",
    only: [:create],
    unless: -> { current_user.present? }

  def new
    @indexable = false
    @list = List.new
  end

  def create
    # Same destination as a real success: a bot redirected somewhere else has
    # learned its submission was discarded.
    return redirect_to(thanks_path) if honeypot_filled?

    result = Services::Lists::Submission.call(
      list_class: @list_class,
      attributes: list_params.to_h,
      user: current_user,
      submitter_email: params[:submitter_email],
      submitter_ip: visitor_ip
    )

    if result.success?
      # deliver_later, not deliver_now: legacy built and sent this inline in the
      # request, blocking the submitter on SendGrid with no retry.
      AdminMailer.new_list_submission(result.data).deliver_later
      redirect_to thanks_path
    else
      @indexable = false
      @list = @list_class.new(list_params)
      @error = result.errors.to_sentence
      render :new, status: :unprocessable_entity
    end
  end

  # Cacheable GET, reached only via the redirect from #create. Exists so the
  # confirmation can be shown without a flash -- public layouts render none.
  def thanks
    @indexable = false
  end

  private

  def set_submittable_types
    @submittable_types = Services::Lists::SubmissionRegistry.types_for(Current.domain)
    raise ActionController::BadRequest, "No submittable list types" if @submittable_types.empty?
  end

  # Never constantize. When the type picker isn't rendered (a single-type
  # domain -- see the form's guard on @submittable_types.many?), a genuine
  # browser POST carries no list_type at all, so the domain's lone type is the
  # default. But a submitted list_type ALWAYS goes through the registry, even on
  # a single-type domain -- otherwise a hand-crafted POST naming another
  # domain's class would ride the "only one type" shortcut straight past
  # validation instead of being rejected.
  def set_list_class
    @list_class =
      if params[:list_type].present?
        Services::Lists::SubmissionRegistry.resolve(Current.domain, params[:list_type])
      elsif @submittable_types.one?
        @submittable_types.first
      end

    raise ActionController::BadRequest, "Unknown list type" if @list_class.nil?
  end

  # A bot fills every input it finds.
  def honeypot_filled?
    params[:website].present?
  end

  def list_params
    # ActionController::Parameters.new, not {} -- Hash has no #permit, so a POST
    # with no list key at all would 500 instead of returning a validation error.
    #
    # is_a?(ActionController::Parameters) guards a SCALAR list param too:
    # #fetch only wraps Hash/Array values in Parameters, so list=x (a plain
    # String) or list[]=x (an Array) comes back as-is, and String/Array have no
    # #permit -- an anonymous POST could otherwise 500 this public endpoint on
    # any of the three live sites, in a loop.
    submitted = params.fetch(:list, ActionController::Parameters.new)
    submitted = ActionController::Parameters.new unless submitted.is_a?(ActionController::Parameters)
    submitted.permit(*Services::Lists::Submission::PERMITTED)
  end

  def render_rate_limited
    @indexable = false
    @list = @list_class.new(list_params)
    @error = "Thanks — you've sent us several lists just now. Please try again shortly."
    render :new, status: :too_many_requests
  end

  # Four sites share one route file, so each domain names its own helpers.
  # fetch, not []: a domain with no thanks path is a wiring mistake that should
  # raise in that domain's own tests, not produce a nil redirect in production.
  THANKS_PATHS = {
    books: :books_list_submission_thanks_path,
    music: :music_list_submission_thanks_path,
    games: :games_list_submission_thanks_path
  }.freeze

  def thanks_path
    public_send(THANKS_PATHS.fetch(Current.domain))
  end
  helper_method :thanks_path

  LISTS_PATHS = {
    books: :books_lists_path,
    music: :music_lists_path,
    games: :games_lists_path
  }.freeze

  def domain_lists_path
    public_send(LISTS_PATHS.fetch(Current.domain))
  end
  helper_method :domain_lists_path

  def domain_layout
    "#{Current.domain}/application"
  end
end
