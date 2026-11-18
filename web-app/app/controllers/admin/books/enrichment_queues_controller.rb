class Admin::Books::EnrichmentQueuesController < Admin::EnrichmentQueuesBaseController
  private

  def domain = :books

  def route_prefix = "admin_books_"
end
