# Books -> Publisher Intake -> Titles: what the intake jobs hold (design §9).
# Read-only. A plain page, not a Turbo Frame, so filter and pagination links
# need no frame opt-out.
class Admin::Books::PublisherTitlesController < Admin::Books::BaseController
  PER_PAGE = 50
  STATUSES = ::Books::PublisherTitle.statuses.keys.freeze
  HOLD_REASONS = ::Books::PublisherTitle.hold_reasons.keys.freeze

  helper_method :source_options

  def index
    authorize ::Books::PublisherTitle
    scope = ::Books::PublisherTitle.all
    scope = scope.where(source: params[:source]) if source_options.include?(params[:source])
    scope = scope.where(status: params[:status]) if STATUSES.include?(params[:status])
    scope = scope.where(hold_reason: params[:hold_reason]) if HOLD_REASONS.include?(params[:hold_reason])
    @pagy, @titles = pagy(scope.upcoming_first, limit: PER_PAGE)
  end

  def show
    @title = ::Books::PublisherTitle.find(params[:id])
    authorize @title
    @listings = @title.listings.order(:id)
  end

  private

  def source_options
    @source_options ||= (::Books::PublisherIntake::Sources.registry.keys +
      ::Books::PublisherTitle.distinct.pluck(:source)).uniq.sort
  end
end
