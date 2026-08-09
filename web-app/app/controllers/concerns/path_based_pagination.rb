module PathBasedPagination
  extend ActiveSupport::Concern

  private

  # A paged URL must never render a fallback body: Cacheable would store one
  # edge entry per bogus page number.
  def reject_paged_request!
    raise ActiveRecord::RecordNotFound if params[:page].to_i > 1
  end

  # Wraps pagy with the path-based options and a bounds check. Pagy serves an
  # empty 200 for any page past the last one, which would let a crawler mint
  # unbounded thin pages that Cacheable then stores at the edge for six hours.
  # An empty page 1 stays legitimate because @pagy.last floors at 1.
  def pagy_path(collection, **options)
    pagy, records = pagy(collection, **options, **pagy_path_options)
    raise ActiveRecord::RecordNotFound if pagy.page > pagy.last

    [pagy, records]
  end

  # pagy_path's sibling for a collection the caller has already paged. A saved
  # search's page is sized by OpenSearch, so there is nothing left for pagy to
  # slice and no relation for it to count -- it only needs to build the nav.
  #
  # Pagy's OffsetPaginator honours a pre-set :count (`options[:count] ||=`), so
  # passing an empty collection never triggers a count query; the records it
  # hands back are discarded and the caller renders its own. The bounds check is
  # pagy_path's, for the same reason: pagy serves an empty 200 past the last
  # page, which is an unbounded space of thin pages.
  def pagy_path_count(count, **options)
    pagy, _records = pagy(:offset, [], count: count, **options, **pagy_path_options)
    raise ActiveRecord::RecordNotFound if pagy.page > pagy.last

    pagy
  end

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
