module Books::DefaultHelper
  def books_robots_content
    return "noindex, follow" unless Books::PublicIndexing.enabled?
    return "noindex, follow" if params[:ranking_configuration_id].present?

    @indexable ? "index, follow" : "noindex, follow"
  end
end
