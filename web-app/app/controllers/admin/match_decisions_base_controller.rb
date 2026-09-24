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

  before_action :set_decision, only: [:show]

  OUTCOMES = ::MatchDecision.outcomes.keys.freeze
  CONFIDENCES = ::MatchDecision.confidences.keys.freeze
  DECIDED_BY = ::MatchDecision.defined_enums.fetch("decided_by").keys.freeze
  REVIEWED = %w[pending reviewed all].freeze
  VERIFY = %w[hide include].freeze
  FILTER_KEYS = %w[entity outcome confidence decided_by reviewed verify].freeze
  PER_PAGE = 50

  helper_method :filter_params, :decisions_index_path, :decision_path, :entries, :entry_for

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
end
