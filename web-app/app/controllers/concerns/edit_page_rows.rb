# Loads one page of a list's items exactly as the Edit page shows them. The
# edit action and the item write actions (which morph the rows in place) both
# use it, so the rows a write answers with match a fresh page load.
module EditPageRows
  extend ActiveSupport::Concern

  EDIT_PAGE_LIMIT = 100

  private

  # [pagy, items] for page `page` of the list. A page past the end is the last
  # page (a removal can empty the page the member was on).
  def load_edit_rows(list, page:)
    pagy, items = paged_edit_rows(list, page)
    pagy, items = paged_edit_rows(list, pagy.last) if pagy.page > pagy.last
    [pagy, items]
  end

  def paged_edit_rows(list, page)
    scope = list.user_list_items.ordered.includes(listable: list.class.listable_display_includes)
    pagy(
      scope,
      limit: EDIT_PAGE_LIMIT,
      page: page,
      request: {base_url: request.base_url, path: edit_my_list_path(list), params: {}},
      page_path: ->(n) { (n == 1) ? edit_my_list_path(list) : edit_my_list_page_path(list, n) }
    )
  end

  def requested_page
    Integer(params[:page].to_s, 10, exception: false)&.clamp(1, nil) || 1
  end
end
