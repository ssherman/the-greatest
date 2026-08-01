module PathBasedPagination
  extend ActiveSupport::Concern

  private

  def pagy_path_options
    {request: pagy_path_request, page_path: Pagination::PathBuilder.from_request(request)}
  end

  # pagy appends whatever params it is given as a query string once the page key is
  # removed, and request.params includes route parameters -- so passing it whole
  # would echo filters such as :year back into the query string. Pass only real
  # query params, plus :page, which pagy needs in order to resolve the current page
  # when it arrives as a route segment.
  def pagy_path_request
    {
      base_url: request.base_url,
      path: request.path,
      params: request.query_parameters.merge(
        request.path_parameters.slice(:page).stringify_keys
      )
    }
  end
end
