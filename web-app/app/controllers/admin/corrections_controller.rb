class Admin::CorrectionsController < Admin::BaseController
  include Admin::DomainScopedAuth
  include Pagy::Method

  # Task 12 adds apply/reject/resolve and extends this list. Listing them here
  # already, before those actions exist, would break EVERY request to this
  # controller: Rails validates the whole :only array on every dispatch (not
  # just the current action) whenever raise_on_missing_callback_actions is on,
  # which config/environments/{development,test}.rb both set.
  before_action :set_correction, only: [:show]

  STATUSES = %w[pending resolved rejected].freeze

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

  private

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

  # Authorize against the corrected RECORD's domain, not the request host --
  # same rule as Admin::DescriptionsController.
  def domain_auth_parent
    return nil if params[:id].blank?

    ::Correction.find_by(id: params[:id])&.correctable
  end
end
