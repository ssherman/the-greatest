module Books::DefaultHelper
  def books_robots_content
    return "noindex, follow" unless Books::PublicIndexing.enabled?
    return "noindex, follow" if params[:ranking_configuration_id].present?

    @indexable ? "index, follow" : "noindex, follow"
  end

  def books_lists_path_with_rc(**options)
    rc = params[:ranking_configuration_id].presence
    rc ? books_rc_lists_path(rc, **options) : books_lists_path(**options)
  end

  def books_list_path_with_rc(id, **options)
    rc = params[:ranking_configuration_id].presence
    rc ? books_rc_list_path(rc, id, **options) : books_list_path(id, **options)
  end
end
