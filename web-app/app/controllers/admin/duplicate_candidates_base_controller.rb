# The audit surface for duplicate_candidates (spec §13): suspected pairs of
# one domain's records, side by side. Each domain supplies a routable
# subclass naming its domain and route prefix (see
# Admin::Books::DuplicateCandidatesController); every query is scoped to the
# models DataImporters::FinderRegistry registers for that domain.
#
# Merging is not done here. The merge forms post to the domain's existing
# execute_action endpoint, whose delete gate and merger stand; on success the
# merger's Services::DuplicateCandidates::RecordMerge hook marks the pair
# merged. Dismissal is the one write this controller owns.
class Admin::DuplicateCandidatesBaseController < Admin::BaseController
  include Admin::DomainScopedAuth

  before_action :set_pair, only: [:dismiss]
  before_action :require_domain_write!, only: [:dismiss]

  STATUSES = ::DuplicateCandidate.statuses.keys.freeze
  PER_PAGE = 25

  helper_method :duplicates_index_path, :dismiss_duplicate_path, :decision_path_for,
    :entry_for_pair, :record_for, :summary_for

  def index
    @status = STATUSES.include?(params[:status]) ? params[:status] : "pending"
    @counts = domain_scope.group(:status).count
    @pagy, @pairs = pagy(domain_scope.where(status: @status).includes(:match_decision, :resolved_by).newest_first, limit: PER_PAGE)
    load_pair_records(@pairs)
  end

  def dismiss
    unless @pair.pending?
      redirect_to duplicates_index_path(status: @pair.status), alert: "This pair is already #{@pair.status.humanize.downcase}."
      return
    end

    @pair.update!(status: :not_duplicate, resolved_at: Time.current, resolved_by: current_user,
      resolution_note: params[:resolution_note].presence)
    redirect_to duplicates_index_path, notice: "Marked as not a duplicate."
  end

  private

  def domain
    raise NotImplementedError, "Subclass must implement domain"
  end

  def route_prefix
    raise NotImplementedError, "Subclass must implement route_prefix"
  end

  def entries
    DataImporters::FinderRegistry.for_domain(domain)
  end

  def domain_scope
    ::DuplicateCandidate.where(item_type: entries.map(&:model))
  end

  def set_pair
    @pair = domain_scope.find(params[:id])
  end

  def entry_for_pair(pair)
    DataImporters::FinderRegistry.entry_for_model(pair.item_type)
  end

  # One query per item type for the records and one finder per type for
  # their summaries (FinderBase#summarize: title, creators, year, ranked
  # position, list count, identifiers). A record a merge or delete has since
  # removed is simply absent; its side says so and the row offers dismissal
  # only. ranked_position and list_count are one query each per record --
  # fifty per page at most, accepted for an admin queue.
  def load_pair_records(pairs)
    @records = {}
    @summaries = {}
    pairs.group_by(&:item_type).each do |type, rows|
      entry = DataImporters::FinderRegistry.entry_for_model(type)
      next unless entry

      finder = entry.finder_class.new
      ids = rows.flat_map { |row| [row.item_a_id, row.item_b_id] }.uniq
      entry.model_class.where(id: ids).includes(:identifiers, *entry.preloads).each do |record|
        @records[[type, record.id]] = record
        @summaries[[type, record.id]] = finder.summarize(record)
      end
    end
  end

  def record_for(pair, id)
    @records[[pair.item_type, id]]
  end

  def summary_for(pair, id)
    @summaries[[pair.item_type, id]]
  end

  def duplicates_index_path(params = {})
    public_send(:"#{route_prefix}duplicate_candidates_path", params)
  end

  def dismiss_duplicate_path(pair)
    public_send(:"dismiss_#{route_prefix}duplicate_candidate_path", pair)
  end

  def decision_path_for(decision)
    public_send(:"#{route_prefix}match_decision_path", decision)
  end
end
