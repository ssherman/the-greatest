# The audit surface for duplicate_candidates (spec §13): suspected pairs of
# one domain's records, side by side. Each domain supplies a routable
# subclass naming its domain and route prefix (see
# Admin::Books::DuplicateCandidatesController); every query is scoped to the
# models DataImporters::FinderRegistry registers for that domain.
#
# Both writes, dismissal and merge, redirect back to the exact index URL the
# form was posted from (return_to). Turbo treats a redirect to the current
# URL as a page refresh, which the index morphs with the scroll position
# kept, so working through the queue never loses the admin's place. A merge
# runs the domain's own merge action behind the same delete gate as the
# record pages' execute_action; the merger's
# Services::DuplicateCandidates::RecordMerge hook marks the pair merged.
class Admin::DuplicateCandidatesBaseController < Admin::BaseController
  include Admin::DomainScopedAuth

  before_action :set_pair, only: [:dismiss, :merge]
  before_action :require_domain_write!, only: [:dismiss, :merge]

  STATUSES = ::DuplicateCandidate.statuses.keys.freeze
  VIAS = ::DuplicateCandidate.resolved_via.keys.freeze
  PER_PAGE = 100

  helper_method :duplicates_index_path, :dismiss_duplicate_path, :merge_duplicate_path, :decision_path_for,
    :entry_for_pair, :record_for, :summary_for

  def index
    @status = STATUSES.include?(params[:status]) ? params[:status] : "pending"
    @counts = domain_scope.group(:status).count
    # The via filter narrows resolved tabs only; pending pairs have no resolver.
    @via = params[:via] if VIAS.include?(params[:via]) && @status != "pending"
    pairs = domain_scope.where(status: @status).includes(:match_decision, :resolved_by).newest_first
    pairs = pairs.where(resolved_via: @via) if @via
    @pagy, @pairs = pagy(pairs, limit: PER_PAGE)

    # Resolving the last pairs on the last page leaves that page's URL past
    # the end.
    if @pairs.empty? && @pagy.page > 1
      redirect_to duplicates_index_path(status: @status, via: @via, page: @pagy.last)
      return
    end

    load_pair_records(@pairs)
    @agent_prompt = agent_prompt
  end

  def dismiss
    unless @pair.pending?
      back_to_index(alert: "This pair is already #{@pair.status.humanize.downcase}.", status: @pair.status)
      return
    end

    @pair.update!(status: :not_duplicate, resolved_at: Time.current, resolved_by: current_user,
      resolved_via: :admin_ui,
      resolution_note: params[:resolution_note].presence)
    back_to_index(notice: "Marked as not a duplicate.")
  end

  def merge
    entry = entry_for_pair(@pair)
    unless @pair.pending?
      back_to_index(alert: "This pair is already #{@pair.status.humanize.downcase}.", status: @pair.status)
      return
    end
    unless entry&.mergeable?
      back_to_index(alert: "#{entry&.label || @pair.item_type} records cannot be merged.")
      return
    end

    # A merge elsewhere re-keys every pending pair naming its source onto the
    # survivor, in place. Merge only the records the form showed, or a stale
    # page would merge a book its admin never saw.
    source_id = params[:source_id].to_i
    target_id = params[:target_id].to_i
    unless [source_id, target_id].minmax == [@pair.item_a_id, @pair.item_b_id]
      back_to_index(alert: "This pair changed since the page loaded. Nothing was merged.")
      return
    end

    records = entry.model_class.where(id: [source_id, target_id]).index_by(&:id)
    source = records[source_id]
    target = records[target_id]
    unless source && target
      back_to_index(alert: "One of these records no longer exists. Nothing was merged.")
      return
    end

    # The delete gate execute_action applies to a destructive action: the
    # merge destroys the source.
    authorize source, :destroy?
    action_class = "Actions::Admin::#{domain.to_s.camelize}::#{entry.merge_action}".constantize
    result = action_class.call(user: current_user, models: [target],
      fields: {entry.source_field => source.id.to_s, "confirm_merge" => params[:confirm_merge]})

    flash_type = if result.success?
      :notice
    else
      (result.warning? ? :warning : :alert)
    end
    back_to_index(flash_type => result.message)
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

  # The starting prompt the page's Copy prompt button copies. A domain with no
  # config/mcp/<domain>/prompts/duplicates.md.erb gets no button.
  def agent_prompt
    file = Rails.root.join("config", "mcp", domain.to_s, "prompts", "duplicates.md.erb")
    return unless file.exist?

    pending = domain_scope.pending.group(:item_type).count
    ERB.new(file.read).result_with_hash(
      mcp_url: "#{Api::Host.base_url}/api/mcp/admin",
      pending_books: pending["Books::Book"].to_i,
      pending_authors: pending["Books::Author"].to_i
    )
  end

  def set_pair
    @pair = domain_scope.find(params[:id])
  end

  # Back to the index URL the form named, exactly as it was requested, so the
  # redirect lands on the current URL and Turbo refreshes in place. Anything
  # that is not this domain's index falls back to it.
  def back_to_index(status: nil, **messages)
    redirect_to return_to_path || duplicates_index_path(status: status), flash: messages
  end

  def return_to_path
    location = url_from(params[:return_to])
    location if location && URI.parse(location).path == duplicates_index_path
  rescue URI::InvalidURIError
    nil
  end

  def entry_for_pair(pair)
    DataImporters::FinderRegistry.entry_for_model(pair.item_type)
  end

  # See Services::DuplicateCandidates::PairRecords; a record a merge or delete
  # has since removed is absent, its side says so and the row offers dismissal
  # only.
  def load_pair_records(pairs)
    loaded = ::Services::DuplicateCandidates::PairRecords.call(pairs)
    @records = loaded.records
    @summaries = loaded.summaries
  end

  def record_for(pair, id)
    @records[[pair.item_type, id]]
  end

  def summary_for(pair, id)
    @summaries[[pair.item_type, id]]
  end

  def duplicates_index_path(params = {})
    public_send(:"#{route_prefix}duplicate_candidates_path", params.compact)
  end

  def dismiss_duplicate_path(pair)
    public_send(:"dismiss_#{route_prefix}duplicate_candidate_path", pair)
  end

  def merge_duplicate_path(pair)
    public_send(:"merge_#{route_prefix}duplicate_candidate_path", pair)
  end

  def decision_path_for(decision)
    public_send(:"#{route_prefix}match_decision_path", decision)
  end
end
