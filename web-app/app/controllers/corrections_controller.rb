class CorrectionsController < ApplicationController
  include Cacheable
  include VisitorIp

  layout :domain_layout

  # The form page is edge-cached, so its <meta name="csrf-token"> belongs to
  # whoever populated the cache. The Stimulus controller fetches a real token from
  # /correction_token on first interaction -- but if that fetch never happened (JS
  # off, blocked, slow), null_session accepts the write as ANONYMOUS rather than
  # raising and showing the submitter a 422 they cannot act on.
  #
  # This is sound, not a compromise. CSRF exists to stop a forged request riding a
  # victim's ambient session authority; null_session removes exactly that
  # authority, so what lands is an anonymous correction the attacker could have
  # posted directly -- and it is moderated before it touches a record. The only
  # thing lost is attribution for a signed-in user whose token fetch failed.
  protect_from_forgery with: :null_session, only: [:create]

  before_action :set_record, only: [:new, :thanks]
  before_action :cache_for_show_page, only: [:new, :thanks]
  before_action :prevent_caching, only: [:create]
  before_action :set_record_from_params, only: [:create]

  # Five an hour is far above any human correcting books they are reading, and it
  # caps a script at 120/day per address rather than unbounded.
  #
  # by: goes through visitor_ip, NOT request.remote_ip -- see the VisitorIp
  # concern. remote_ip in production is the Cloudflare edge IP, so keying on it
  # would put every visitor in one bucket and lock out the whole site at the fifth
  # submission of the hour.
  #
  # with: is not optional. Rails' default raises TooManyRequests, which renders an
  # HTML error body.
  #
  # with: renders the form again instead of redirecting: the redirect target
  # (the record's show page) is edge-cached with skip_session_for_caching, so a
  # flash set on a redirect there is never read, let alone shown. Rendering here
  # is uncached (prevent_caching runs before this filter) and can carry @error
  # straight into the response.
  #
  # Declared AFTER set_record_from_params, and that ordering is load-bearing:
  # filters run in declaration order and rate_limit installs its own before_action,
  # so @record is already set when the with: lambda builds @fields and renders
  # :new. Move this above that filter and a throttled request raises
  # NoMethodError on nil instead of showing the rate-limit message.
  rate_limit to: 5, within: 1.hour,
    by: -> { current_user&.id || visitor_ip },
    with: -> {
      @indexable = false
      @fields = @record.class.correctable_fields.values
      @error = "Thanks — you've sent us several corrections just now. Please try again shortly."
      render :new, status: :too_many_requests
    },
    store: Rails.application.config.x.rate_limit_store,
    name: "corrections-create",
    only: [:create]

  def new
    # The books layout emits "noindex, follow" unless @indexable is truthy, so nil
    # would already do it. Explicit, because "not indexed" here is a decision, not
    # an accident of a default.
    @indexable = false
    @fields = @record.class.correctable_fields.values
  end

  def create
    # Same destination as a real success (see correction_thanks_path) -- a bot
    # that gets redirected somewhere else on a filled honeypot has learned its
    # submission was discarded.
    return redirect_to(correction_thanks_path) if honeypot_filled?

    result = Services::Corrections::Submission.call(
      record: @record,
      field_params: field_params,
      notes: params.dig(:correction, :notes),
      user: current_user,
      submitter_ip: visitor_ip
    )

    if result.success?
      # deliver_later, not deliver_now: legacy built and sent this inline in the
      # request, which blocked the submitter on SendGrid and had no retry.
      AdminMailer.new_correction(result.data).deliver_later
      # The record's show page is edge-cached and skips the session, so a flash
      # set here would never be read -- and a cached copy would show one
      # visitor's message to every other visitor. Redirect to the dedicated
      # thanks page instead, which states the confirmation as static content.
      redirect_to correction_thanks_path
    else
      @indexable = false
      @fields = @record.class.correctable_fields.values
      @error = result.errors.to_sentence
      render :new, status: :unprocessable_entity
    end
  end

  # Cacheable GET, reached only via the redirect from #create. Exists so the
  # PRG success message can be shown without a flash -- see the comment on the
  # #create redirect above.
  def thanks
    @indexable = false
  end

  private

  # correctable_type is a ROUTE DEFAULT here, not a param -- see config/routes.rb.
  # It still goes through the registry rather than constantize, so the two callers
  # (#new and #create) share one resolution path and neither can drift.
  def set_record
    @correctable_type = params[:correctable_type]
    klass = Services::Corrections::TypeRegistry.resolve(@correctable_type)
    raise ActionController::BadRequest, "Unknown correctable type" if klass.nil?

    @record = klass.find_by!(slug: params[:slug])
  end

  def set_record_from_params
    @correctable_type = params[:correctable_type]
    klass = Services::Corrections::TypeRegistry.resolve(@correctable_type)
    raise ActionController::BadRequest, "Unknown correctable type" if klass.nil?

    # find_by!(id:), NEVER find. Books::Book is friendly_id with :finders, so
    # find("123") resolves the SLUG "123" before the primary key -- and this corpus
    # has 137 purely-numeric slugs, so `find` would file corrections against the
    # wrong book. Same trap the Amazon work hit.
    @record = klass.find_by!(id: params[:correctable_id])
  end

  # A bot fills every input it finds. A filled honeypot is discarded, and the
  # caller still gets the ordinary success redirect -- a 200 stops a bot retrying,
  # where a 422 brings it back.
  def honeypot_filled?
    params[:website].present?
  end

  def field_params
    submitted = params.dig(:correction, :fields)
    return {} if submitted.blank?

    # permit! then to_h, not permit(a list): the field set is per-model and comes
    # from the declaration, and Submission already drops every key that is not
    # declared. Permitting a computed list here would be the same allowlist,
    # written twice.
    submitted.permit!.to_h
  end

  # Where to send the submitter back to. There is no single root-relative show
  # helper in this app -- four sites share one route file, so each domain names its
  # own -- which is why this is a lookup rather than polymorphic_path.
  PUBLIC_PATHS = {
    "Books::Book" => :book_path,
    "Music::Album" => :album_path,
    "Games::Game" => :game_path
  }.freeze

  # fetch, not []: a correctable type with no public path is a wiring mistake, and
  # it should raise in that domain's own tests rather than produce a `nil` redirect
  # in production.
  def correctable_path
    public_send(PUBLIC_PATHS.fetch(@correctable_type), slug: @record.slug)
  end
  helper_method :correctable_path

  # Same lookup shape as PUBLIC_PATHS, one level down: where #thanks lives for
  # each correctable type. Kept separate from PUBLIC_PATHS (rather than deriving
  # one from the other) because Admin::CorrectionsController already reuses
  # PUBLIC_PATHS for its own "view public page" link -- growing that lookup's
  # shape would ripple into a controller this task has no reason to touch.
  THANKS_PATHS = {
    "Books::Book" => :books_book_correction_thanks_path,
    "Music::Album" => :music_album_correction_thanks_path,
    "Games::Game" => :games_game_correction_thanks_path
  }.freeze

  def correction_thanks_path
    public_send(THANKS_PATHS.fetch(@correctable_type), slug: @record.slug)
  end
  helper_method :correction_thanks_path

  def domain_layout
    "#{Current.domain}/application"
  end
end
