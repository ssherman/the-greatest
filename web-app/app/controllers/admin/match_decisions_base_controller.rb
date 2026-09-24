# The audit surface for match_decisions (spec §13): the decisions the finders
# of one admin domain recorded. Each domain supplies a routable subclass
# naming its domain and route prefix (see Admin::Books::MatchDecisionsController);
# every query here is scoped to the finders DataImporters::FinderRegistry
# registers for that domain, so a books admin never reads, reviews or
# re-checks a music decision by id.
#
# Defaults are the queue's: decisions needing review and not yet reviewed,
# with verify runs hidden -- the duplicate sweep writes one verify: true row
# per ranked book, which would bury the imports this page exists for.
class Admin::MatchDecisionsBaseController < Admin::BaseController
  include Admin::DomainScopedAuth

  before_action :set_decision, only: [:show, :review, :recheck]
  before_action :require_domain_write!, only: [:review, :recheck]

  OUTCOMES = ::MatchDecision.outcomes.keys.freeze
  CONFIDENCES = ::MatchDecision.confidences.keys.freeze
  DECIDED_BY = ::MatchDecision.defined_enums.fetch("decided_by").keys.freeze
  REVIEWED = %w[pending reviewed all].freeze
  VERIFY = %w[hide include].freeze
  FILTER_KEYS = %w[entity outcome confidence decided_by reviewed verify].freeze
  PER_PAGE = 50

  helper_method :filter_params, :decisions_index_path, :decision_path, :entries, :entry_for,
    :review_decision_path, :recheck_decision_path, :ai_chat_path_for

  def index
    @reviewed = REVIEWED.include?(params[:reviewed]) ? params[:reviewed] : "pending"
    @verify = VERIFY.include?(params[:verify]) ? params[:verify] : "hide"
    @pagy, @decisions = pagy(filtered_scope.includes(:record, :reviewed_by).newest_first, limit: PER_PAGE)
  end

  def show
    @entry = entry_for(@decision)
    @candidate_records = candidate_records(@decision)
    @compare = domain_scope.find_by(id: params[:compare]) if params[:compare].present?
  end

  def review
    if @decision.reviewed_at.present?
      redirect_to decision_path(@decision), alert: "Already reviewed."
      return
    end

    @decision.review!(by: current_user, note: params[:review_note].presence)
    redirect_to decision_path(@decision), notice: "Marked reviewed."
  end

  # Runs the finder again, synchronously, with verify on: no early exit, every
  # source, the AI when the rules cannot decide. The finder records the new
  # decision itself; the show page renders it beside the old one. Offered
  # only where FinderRegistry says the finder's real sources have landed --
  # on a legacy-only finder verify would send one candidate to the AI for
  # nothing. Books this takes roughly the Open Library resolve plus the AI
  # call, within a request, which spec §13 accepts.
  def recheck
    entry = entry_for(@decision)
    unless entry&.recheck?
      redirect_to decision_path(@decision), alert: "Re-check is not available for #{entry&.label&.downcase || @decision.finder} decisions yet."
      return
    end

    query = entry.query_class.from_snapshot(@decision.query)
    match = entry.finder_class.new.call(
      query: query, verify: true, subject: @decision.subject, exclude: recheck_exclusion(@decision, entry)
    )

    redirect_to decision_path(match.decision, compare: @decision.id),
      notice: "Re-checked: #{match.outcome}, #{match.confidence} confidence, decided by #{match.decided_by}."
  end

  private

  def domain
    raise NotImplementedError, "Subclass must implement domain"
  end

  # "admin_books_", "admin_" (music's namespace has no as:), "admin_games_".
  def route_prefix
    raise NotImplementedError, "Subclass must implement route_prefix"
  end

  def entries
    DataImporters::FinderRegistry.for_domain(domain)
  end

  def entry_for(decision)
    DataImporters::FinderRegistry.entry(decision.finder)
  end

  def domain_scope
    ::MatchDecision.where(finder: entries.map(&:finder))
  end

  def filtered_scope
    scope = domain_scope
    # The full registry, not the domain-scoped `entries`: an entity label that
    # belongs to another domain (params[:entity] == "album" on a books
    # controller) must still resolve to a real entry so the finder filter
    # below intersects with domain_scope's own finder list and returns
    # nothing -- as opposed to an entity that matches no label anywhere
    # ("cheese"), which is ignored rather than filtered.
    entity = DataImporters::FinderRegistry::ENTRIES.find { |entry| entry.label.parameterize == params[:entity].to_s }
    scope = scope.where(finder: entity.finder) if entity
    scope = scope.where(outcome: params[:outcome]) if OUTCOMES.include?(params[:outcome])
    scope = scope.where(confidence: params[:confidence]) if CONFIDENCES.include?(params[:confidence])
    scope = scope.where(decided_by: params[:decided_by]) if DECIDED_BY.include?(params[:decided_by])
    scope = case @reviewed
    when "pending" then scope.needing_review
    when "reviewed" then scope.where.not(reviewed_at: nil)
    else scope
    end
    scope = scope.where(verify: false) if @verify == "hide"
    scope
  end

  def set_decision
    @decision = domain_scope.find(params[:id])
  end

  # The local records the candidate snapshots name, one query per type, so
  # the candidate table can link them and the merge forms can target them.
  # Keyed by [record_type, record_id]; a record since merged away is absent.
  def candidate_records(decision)
    decision.candidates.group_by { |candidate| candidate["record_type"] }.each_with_object({}) do |(type, snapshots), records|
      entry = DataImporters::FinderRegistry.entry_for_model(type)
      next unless entry

      entry.model_class.where(id: snapshots.map { |candidate| candidate["record_id"] }).each do |record|
        records[[type, record.id]] = record
      end
    end
  end

  def filter_params(overrides = {})
    request.query_parameters.slice(*FILTER_KEYS).merge(overrides.stringify_keys).compact
  end

  def decisions_index_path(params = {})
    public_send(:"#{route_prefix}match_decisions_path", params)
  end

  def decision_path(decision, params = {})
    public_send(:"#{route_prefix}match_decision_path", decision, params)
  end

  # This domain's AI Chats page for the chat behind an AI decision; every
  # domain's admin namespace routes `resources :ai_chats` with the same prefix
  # as its match decisions.
  def ai_chat_path_for(ai_chat)
    public_send(:"#{route_prefix}ai_chat_path", ai_chat)
  end

  # What the re-run must not consider. A decision made for a record of this
  # finder's own type (the sweep's subject) re-resolves that record against
  # the rest of the catalog, so the record is excluded. An unmatched import
  # created its record from this very query, so that record is excluded or
  # the re-check would match itself. A matched import excludes nothing: the
  # question is whether the match still holds.
  def recheck_exclusion(decision, entry)
    return decision.subject if decision.subject.instance_of?(entry.model_class)

    decision.record if decision.unmatched?
  end

  def review_decision_path(decision)
    public_send(:"review_#{route_prefix}match_decision_path", decision)
  end

  def recheck_decision_path(decision)
    public_send(:"recheck_#{route_prefix}match_decision_path", decision)
  end
end
