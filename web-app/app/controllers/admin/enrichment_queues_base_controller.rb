# The admin page for the enrichment queues (EnrichmentRequest): per type, the
# counts, the Copy prompt an agent is started with, a Fill form, the items and a
# Re-queue button. Each domain supplies a routable subclass naming its domain and
# route prefix (see Admin::Books::EnrichmentQueuesController); the types come
# from Services::EnrichmentQueue::Registry, so a new type needs no change here.
#
# Fill only enqueues a job: the fill walks the candidates in the background, and
# the page is reloaded to see the counts move.
class Admin::EnrichmentQueuesBaseController < Admin::BaseController
  include Admin::DomainScopedAuth

  before_action :set_type, only: [:show, :fill]
  before_action :set_request, only: [:requeue]
  before_action :require_domain_write!, only: [:fill, :requeue]

  STATUSES = ::EnrichmentRequest.statuses.keys.freeze
  VIAS = ::EnrichmentRequest.resolved_via.keys.freeze
  PER_PAGE = 50

  helper_method :queues_path, :queue_path, :fill_path, :requeue_path, :record_name, :user_name

  def index
    @types = types
    kinds = @types.map(&:kind)
    grouped = ::EnrichmentRequest.where(kind: kinds).group(:kind, :status).count
    @counts = kinds.index_with do |kind|
      STATUSES.index_with { |status| grouped.fetch([kind, status], 0) }
    end
    @prompts = @types.index_with { |type| ::Services::AgentPrompts.for_enrichment(type) }
  end

  def show
    @statuses = STATUSES
    @status = STATUSES.include?(params[:status]) ? params[:status] : "pending"
    grouped = ::EnrichmentRequest.for_kind(@type.kind).group(:status).count
    @counts = STATUSES.index_with { |status| grouped.fetch(status, 0) }
    @vias = VIAS
    @via = params[:via] if VIAS.include?(params[:via]) && resolved_tab?
    rows = ::EnrichmentRequest.for_kind(@type.kind).where(status: @status)
      .includes(:enrichable, :resolved_by, :claimed_by)
    rows = rows.where(resolved_via: @via) if @via
    rows = resolved_tab? ? rows.order(Arel.sql("resolved_at DESC NULLS LAST"), id: :desc) : rows.order(:priority, :id)
    @pagy, @requests = pagy(rows, limit: PER_PAGE)
  end

  def fill
    scope = params[:scope].to_s
    unless ::Services::EnrichmentQueue::Type::SCOPES.include?(scope)
      redirect_to queues_path, alert: "Unknown scope. Choose ranked or all."
      return
    end

    limit = params[:limit].to_s.strip
    unless limit.empty? || limit.match?(/\A[1-9]\d*\z/)
      redirect_to queues_path, alert: "The limit must be a positive whole number, or blank for no limit."
      return
    end

    ::EnrichmentQueue::FillJob.perform_async(@type.kind, scope, limit.empty? ? nil : limit.to_i)
    redirect_to queues_path, notice: "Fill queued for #{@type.label}. It runs in the background: reload this page in a moment to see the counts."
  end

  def requeue
    type = ::Services::EnrichmentQueue::Registry.fetch(@request.kind)
    result = ::Services::EnrichmentQueue::Requeue.call(request: @request, user: current_user)
    if result.success?
      redirect_to queue_path(type), notice: "Put back in the queue."
    else
      redirect_to queue_path(type), alert: result.errors.first[:detail]
    end
  end

  private

  def domain
    raise NotImplementedError, "Subclass must implement domain"
  end

  def route_prefix
    raise NotImplementedError, "Subclass must implement route_prefix"
  end

  def types
    ::Services::EnrichmentQueue::Registry.for_domain(domain)
  end

  def set_type
    @type = ::Services::EnrichmentQueue::Registry.find(domain: domain, slug: params[:type])
    head :not_found unless @type
  end

  def set_request
    @request = ::EnrichmentRequest.where(kind: types.map(&:kind)).find(params[:id])
  end

  def resolved_tab?
    %w[done skipped failed].include?(@status)
  end

  def queues_path
    public_send(:"#{route_prefix}enrichment_queues_path")
  end

  def queue_path(type, params = {})
    public_send(:"#{route_prefix}enrichment_queue_path", type.slug, params.compact)
  end

  def fill_path(type)
    public_send(:"fill_#{route_prefix}enrichment_queue_path", type.slug)
  end

  def requeue_path(request)
    public_send(:"#{route_prefix}requeue_enrichment_request_path", request)
  end

  # A deleted record leaves its row behind (the association has no foreign key).
  def record_name(record)
    return "(deleted)" unless record

    %i[title name].filter_map { |attribute| record.try(attribute).presence }.first || "##{record.id}"
  end

  def user_name(user)
    return unless user

    user.display_name.presence || user.name.presence || user.email
  end
end
