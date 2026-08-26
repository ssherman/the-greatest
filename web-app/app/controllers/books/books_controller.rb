class Books::BooksController < ApplicationController
  include Cacheable

  layout "books/application"

  before_action :load_ranking_configuration, only: [:show, :similar]
  before_action :cache_for_show_page, only: [:show, :similar]

  # Genre, then subject, then location: what kind of book it is, what it is about,
  # then where it is set. The legacy site ordered its sidebar the same way; the
  # bare group_by this replaced took whatever order the database returned, which
  # routinely led with Location. A type outside this list sorts to the end rather
  # than disappearing, and the secondary sort on the name itself keeps that tail
  # deterministic (Ruby's sort_by is not stable).
  CATEGORY_TYPE_ORDER = %w[genre subject location].freeze

  def self.ranking_configuration_class
    Books::RankingConfiguration
  end

  def show
    # find_by!(slug:), never friendly.find: friendly_id resolves slugs before
    # primary keys, so 137 books with purely numeric slugs would otherwise be
    # ambiguous with a book id.
    @book = Books::Book
      .includes(:categories, :descriptions, :review_summary, :countries, :original_language, {book_authors: :author})
      .includes(primary_image: {file_attachment: {blob: {variant_records: {image_attachment: :blob}}}})
      .find_by!(slug: params[:slug])

    # Scoped to a non-null rank: rank is nullable, and an unranked RankedItem would
    # otherwise mark the page indexable and reach `rank.ordinalize` in the view.
    @ranked_item = if @ranking_configuration
      @ranking_configuration.ranked_items.where.not(rank: nil).find_by(item: @book)
    end
    @indexable = @ranked_item.present?
    # An array of [category_type, categories] pairs rather than a Hash -- the view
    # only iterates it, and an array is the only way to pin the order.
    @categories_by_type = @book.categories.active
      .sort_by { |category| category.name.to_s.downcase }
      .group_by(&:category_type)
      .sort_by { |type, _| [CATEGORY_TYPE_ORDER.index(type) || CATEGORY_TYPE_ORDER.size, type.to_s] }
    @description = @book.primary_description

    @list_items = @book.list_items
      .joins(:list)
      .where(list_id: @ranking_configuration.ranked_lists.select(:list_id))
      .where(lists: {status: :active})
      .includes(:list)
      .order(Arel.sql("list_items.position ASC NULLS LAST"), "lists.name")

    # Preloaded above, so this is not a query. Nil for the 72,659 books nobody has
    # rated -- both review components render nothing in that case.
    @review_summary = @book.review_summary

    # Written reviews only, newest first, unpaginated: the most-reviewed book in the
    # corpus has 37. Served by index_reviews_on_reviewable_with_body. No association is
    # preloaded because a review row renders no author.
    @reviews = @book.reviews.with_body.recent

    # Rescued into an empty success inside the service, so an OpenSearch outage
    # costs this card rather than the whole page.
    similar = ::Services::Books::SimilarBooks.call(@book)
    @similar_books = similar.data[:books]
    @more_similar_available = similar.data[:more_available]
  end

  def similar
    # find_by!(slug:), never friendly.find -- 137 books have purely numeric slugs
    # and friendly_id resolves slugs before primary keys. book_authors: :author is
    # preloaded because the view walks it (the same idiom #show preloads above) --
    # without it, every credited author on this book is its own query.
    @book = ::Books::Book
      .includes(book_authors: :author)
      .find_by!(slug: params[:slug])

    @ranked_item = if @ranking_configuration
      @ranking_configuration.ranked_items.where.not(rank: nil).find_by(item: @book)
    end
    @indexable = @ranked_item.present?

    @similar_books = ::Services::Books::SimilarBooks
      .call(@book, limit: Rails.application.config.x.book_similarity[:page_limit])
      .data[:books]
  end
end
