class Books::BooksController < ApplicationController
  include Cacheable

  layout "books/application"

  before_action :load_ranking_configuration, only: [:show]
  before_action :cache_for_show_page, only: [:show]

  def self.ranking_configuration_class
    Books::RankingConfiguration
  end

  def show
    # find_by!(slug:), never friendly.find: friendly_id resolves slugs before
    # primary keys, so 137 books with purely numeric slugs would otherwise be
    # ambiguous with a book id.
    @book = Books::Book
      .includes(:categories, :descriptions, {book_authors: :author})
      .includes(primary_image: {file_attachment: {blob: {variant_records: {image_attachment: :blob}}}})
      .find_by!(slug: params[:slug])

    # Scoped to a non-null rank: rank is nullable, and an unranked RankedItem would
    # otherwise mark the page indexable and reach `rank.ordinalize` in the view.
    @ranked_item = if @ranking_configuration
      @ranking_configuration.ranked_items.where.not(rank: nil).find_by(item: @book)
    end
    @indexable = @ranked_item.present?
    @categories_by_type = @book.categories.active.group_by(&:category_type)
    @description = @book.primary_description

    @list_items = @book.list_items
      .joins(:list)
      .where(list_id: @ranking_configuration.ranked_lists.select(:list_id))
      .where(lists: {status: :active})
      .includes(:list)
      .order(Arel.sql("list_items.position ASC NULLS LAST"), "lists.name")
  end
end
