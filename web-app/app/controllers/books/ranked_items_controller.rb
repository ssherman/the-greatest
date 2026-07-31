class Books::RankedItemsController < RankedItemsController
  include Pagy::Method
  include Cacheable

  layout "books/application"

  before_action :find_ranking_configuration
  before_action :validate_ranking_configuration_type, if: -> { @ranking_configuration.present? }
  before_action :cache_for_index_page, only: [:index]

  def self.ranking_configuration_class
    Books::RankingConfiguration
  end

  def index
    @indexable = true
    @show_hero = params[:page].blank? && params[:ranking_configuration_id].blank?

    @pagy, @ranked_books = pagy(
      Books::RankedBooksQuery.call(ranking_configuration: @ranking_configuration),
      limit: 100,
      request: pagy_path_request,
      page_path: method(:ranked_books_page_path)
    )
  end

  private

  # pagy's Request#get_params reads request.GET/POST only, so Rails route params
  # (the :page segment) never reach it. Pass them explicitly; controller and action
  # are stripped so they cannot leak into a generated query string.
  def pagy_path_request
    {base_url: request.base_url,
     path: request.path,
     params: request.params.except("controller", "action", "ranking_configuration_id").to_h}
  end

  def ranked_books_page_path(page)
    rc_id = params[:ranking_configuration_id]
    page = page.to_i

    if rc_id.present?
      (page <= 1) ? books_rc_path(rc_id) : books_rc_page_path(rc_id, page)
    else
      (page <= 1) ? books_root_path : books_page_path(page)
    end
  end
end
