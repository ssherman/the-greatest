class Music::RankedItemsController < RankedItemsController
  def self.expected_ranking_configuration_type
    nil
  end

  private

  def parse_year_filter
    return unless params[:year].present?

    @year_filter = ::Filters::YearFilter.parse(params[:year], mode: params[:year_mode])
  rescue ArgumentError
    raise ActionController::RoutingError, "Not Found"
  end
end
