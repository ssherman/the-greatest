class Admin::CorrectionsController < Admin::BaseController
  include Admin::DomainScopedAuth
  include Pagy::Method

  # Widened for Task 12's apply/reject/resolve, which all load a single
  # correction by id. bulk_reject is deliberately absent -- it works on a set
  # of ids via correction_ids[], not on params[:id], so it has nothing for
  # set_correction to load. Rails validates the whole :only array on every
  # dispatch (not just the current action) whenever
  # raise_on_missing_callback_actions is on, which config/environments/
  # {development,test}.rb both set -- so naming an action that does not exist
  # here breaks EVERY request to this controller, and naming bulk_reject here
  # would leave @correction nil for it.
  before_action :set_correction, only: [:show, :apply, :reject, :resolve]
  before_action :require_domain_write!, only: [:apply, :reject, :resolve, :bulk_reject]

  # apply does not need this -- Services::Corrections::Applier refuses a
  # non-pending correction itself, and its refusal is the same string. bulk_reject
  # does not need it either: its scope already carries `status: :pending`, so a
  # non-pending id simply is not in the set.
  #
  # reject and resolve had neither. A stale show page -- bfcache, or a second tab
  # left open -- still renders the review controls, so clicking Reject on a
  # correction that was APPLIED minutes ago flipped it to `rejected` and
  # update_all marked its `applied` field rows `rejected` too, while the record
  # kept every value that had been written to it. The audit trail then said
  # nothing was ever applied.
  before_action :ensure_pending!, only: [:reject, :resolve]

  STATUSES = %w[pending resolved rejected].freeze

  # Each domain's admin namespace names its own `resources :corrections` --
  # books gets an `admin_books_` prefix, games an `admin_games_` prefix, and
  # music's `namespace :admin, module: "admin/music"` carries no `as:` at all,
  # so its helpers are the bare `admin_corrections_path` family. See
  # `bin/rails routes -g corrections`.
  ADMIN_PATHS = {
    books: :admin_books_corrections_path,
    music: :admin_corrections_path,
    games: :admin_games_corrections_path
  }.freeze

  def index
    # Defaults to pending. Legacy's index was every changeset ever, newest first,
    # which is a log rather than a queue.
    @status = STATUSES.include?(params[:status]) ? params[:status] : "pending"
    @counts = domain_scope.group(:status).count
    @pagy, @corrections = pagy(filtered_scope)
  end

  def show
    @fields = @correction.correction_fields.order(:field_name)
    @record = @correction.correctable
  end

  def apply
    result = Services::Corrections::Applier.call(
      correction: @correction, accepted: accepted_params, admin: current_user
    )

    if result.success?
      redirect_to correction_path_for(@correction), notice: "Correction applied."
    else
      redirect_to correction_path_for(@correction),
        alert: "Could not apply: #{result.errors.to_sentence}"
    end
  end

  def reject
    ::Correction.transaction do
      @correction.correction_fields.update_all(status: ::CorrectionField.statuses[:rejected])
      @correction.update!(
        status: :rejected, resolved_by: current_user, resolved_at: Time.current,
        resolution_notes: params[:resolution_notes].presence
      )
    end

    redirect_to corrections_index_path, notice: "Correction rejected."
  end

  # For a notes-only correction the admin acted on by hand -- there is nothing for
  # the applier to write, but the queue must stop showing it.
  def resolve
    @correction.update!(
      status: :resolved, resolved_by: current_user, resolved_at: Time.current,
      resolution_notes: params[:resolution_notes].presence
    )

    redirect_to corrections_index_path, notice: "Correction marked resolved."
  end

  def bulk_reject
    scope = domain_scope.where(id: params[:correction_ids], status: :pending)
    count = scope.count

    ::Correction.transaction do
      ::CorrectionField.where(correction_id: scope.select(:id))
        .update_all(status: ::CorrectionField.statuses[:rejected])
      scope.update_all(
        status: ::Correction.statuses[:rejected], resolved_by_id: current_user.id,
        resolved_at: Time.current, updated_at: Time.current
      )
    end

    redirect_to corrections_index_path(status: params[:status]),
      notice: "Rejected #{count} #{"correction".pluralize(count)}."
  end

  # This domain's corrections index -- the plural route each domain's admin
  # namespace generates for `resources :corrections`.
  def corrections_index_path(**options)
    public_send(ADMIN_PATHS.fetch(current_domain.to_sym), **options)
  end
  helper_method :corrections_index_path

  # Resolved from the CORRECTION's own domain, not current_domain -- same rule as
  # domain_auth_parent below. In practice the two agree, because domain_scope
  # already restricts what set_correction can load.
  def correction_path_for(correction)
    domain = Services::Corrections::TypeRegistry.domain_for(correction.correctable_type)
    public_send(singular_correction_helper(domain), correction)
  end
  helper_method :correction_path_for

  def apply_correction_path(correction)
    public_send(:"apply_#{singular_correction_helper(current_domain.to_sym)}", correction)
  end
  helper_method :apply_correction_path

  def reject_correction_path(correction)
    public_send(:"reject_#{singular_correction_helper(current_domain.to_sym)}", correction)
  end
  helper_method :reject_correction_path

  def resolve_correction_path(correction)
    public_send(:"resolve_#{singular_correction_helper(current_domain.to_sym)}", correction)
  end
  helper_method :resolve_correction_path

  def bulk_reject_corrections_index_path(**options)
    public_send(:"bulk_reject_#{ADMIN_PATHS.fetch(current_domain.to_sym)}", **options)
  end
  helper_method :bulk_reject_corrections_index_path

  # The record's own public show page, for the "View public page" link -- reuses
  # the one lookup CorrectionsController already maintains rather than keeping a
  # second copy that could drift from it.
  def public_path_for(record)
    public_send(CorrectionsController::PUBLIC_PATHS.fetch(record.class.name), slug: record.slug)
  end
  helper_method :public_path_for

  private

  # "admin_books_corrections_path" -> "admin_books_correction_path" (and the
  # music/games equivalents) -- the member-route singular for the plural index
  # helper ADMIN_PATHS already names. delete_suffix, not delete_prefix: the
  # music helper carries no domain infix at all.
  def singular_correction_helper(domain)
    ADMIN_PATHS.fetch(domain).to_s.delete_suffix("s_path") + "_path"
  end

  def domain_scope
    ::Correction.where(correctable_type: Services::Corrections::TypeRegistry.types_for_domain(current_domain))
  end

  def filtered_scope
    scope = domain_scope.where(status: @status).includes(:user, :correction_fields, :correctable).recent

    # to_s first: ?q[]=foo arrives as an Array, and sanitize_sql_like needs a
    # String. Same shape this repo already guards against in
    # Admin::StripeEventsController, Admin::DonationsController and
    # Admin::MembershipsController.
    search_query = params[:q].to_s.presence
    return scope unless search_query

    scope.where("corrections.notes ILIKE ?", "%#{::ActiveRecord::Base.sanitize_sql_like(search_query)}%")
  end

  def set_correction
    @correction = domain_scope.find(params[:id])
  end

  # Same destination and same "Could not <verb>: <reason>" shape as apply's
  # failure branch, off the one string Applier already owns -- action_name is
  # "reject" or "resolve", so the three paths cannot drift apart in wording.
  def ensure_pending!
    return if @correction.pending?

    redirect_to correction_path_for(@correction),
      alert: "Could not #{action_name}: #{Services::Corrections::Applier::ALREADY_RESOLVED}"
  end

  # Authorize against the corrected RECORD's domain, not the request host --
  # same rule as Admin::DescriptionsController.
  def domain_auth_parent
    return nil if params[:id].blank?

    ::Correction.find_by(id: params[:id])&.correctable
  end

  # The review form submits a checkbox per accepted field in accepted_fields[],
  # and every row's value in accepted[<name>] whether ticked or not. Slicing by the
  # checkbox list is what makes UNTICKING a box mean anything -- without it, an
  # unticked row's still-submitted input would be applied anyway.
  #
  # permit! is safe: the applier checks every field name against the record's own
  # declaration, so restating an allowlist here would be the same list written twice.
  def accepted_params
    names = Array(params[:accepted_fields])
    return {} if names.empty?

    # is_a? check, not just .present?: a crafted request can send `accepted=foo`
    # (a plain String) instead of the nested `accepted[field]=...` the form always
    # sends, and .permit! is not defined on String. Same shape as the params[:q]
    # array hazard in filtered_scope -- guard the shape, not just presence.
    submitted = params[:accepted].is_a?(ActionController::Parameters) ? params[:accepted].permit!.to_h : {}

    # No normalisation. An array field is edited as one input PER ELEMENT (see
    # show.html.erb), so it arrives already split and ValueCaster only has to
    # strip and drop blanks. There used to be a normalize_accepted here that
    # split a single-element array on "," -- because the form rendered array
    # fields as one comma-joined input -- and since the form always joined, the
    # size == 1 branch always fired: applying ["Good Night, Mr. Tom"] wrote
    # ["Good Night", "Mr. Tom"] to books_books.alternate_titles, silently, and
    # from there into the search index. 4 of the 49 migrated alternate_titles
    # proposals contain an intra-title comma. A separator cannot be chosen safely
    # for free text; one input per element removes the need for one.
    submitted.slice(*names)
  end
end
