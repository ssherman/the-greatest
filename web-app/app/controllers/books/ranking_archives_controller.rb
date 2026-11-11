# Frozen rankings: the books ranking as it stood in a given month. Pages are
# noindex (the books layout does that whenever @indexable is unset) and carry
# no canonical tag, for the reason Books::RankedItemsController documents.
class Books::RankingArchivesController < ApplicationController
  include Pagy::Method
  include Cacheable
  include PathBasedPagination

  layout "books/application"

  before_action :cache_for_index_page, only: [:index]
  before_action :cache_for_show_page, only: [:show]

  PER_PAGE = 100

  # Same preload Books::RankedBooksQuery uses for the live ranking's cards.
  ENTRY_PRELOAD = [{book_authors: :author}, {primary_image: {file_attachment: :blob}}].freeze

  def index
    # summaries leaves out the three big arrays; the list needs none of them.
    @archives = ::Books::RankingArchive.visible.summaries.newest_first
  end

  def show
    @archive = ::Books::RankingArchive.visible.find_by!(slug: params[:slug])
    @pagy = pagy_path_count(@archive.items_count, limit: PER_PAGE)
    @entries = ::Services::RankingArchives::Entries.call(
      archive: @archive, offset: @pagy.offset, limit: @pagy.limit, preload: ENTRY_PRELOAD
    )
  end
end
