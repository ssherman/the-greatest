module Books::DefaultHelper
  def books_robots_content
    return "noindex, follow" unless Books::PublicIndexing.enabled?
    return "noindex, follow" if params[:ranking_configuration_id].present?

    @indexable ? "index, follow" : "noindex, follow"
  end

  # Paging is path-based, so /authors/page/3 is still the Authors page. Pages
  # below a link (a single list, a single author) deliberately don't match: the
  # mark means "you are on this page", not "you are somewhere in this section".
  def books_nav_current?(path)
    (request.path.sub(%r{/page/\d+\z}, "").presence || "/") == path
  end

  # Only the drawer marks the current page; the desktop bar has no styling for it.
  def books_nav_link(name, path, variant)
    current = variant == :vertical && books_nav_current?(path)
    link_to name, path, aria: {current: ("page" if current)}
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
