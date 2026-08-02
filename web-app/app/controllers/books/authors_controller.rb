class Books::AuthorsController < ApplicationController
  include Pagy::Method
  include Cacheable
  include PathBasedPagination

  layout "books/application"

  before_action :load_ranking_configuration
  before_action :load_author
  before_action :cache_for_show_page

  def self.ranking_configuration_class
    Books::RankingConfiguration
  end

  def show
    @ranked_item = author_ranked_item
    @indexable = @ranked_item.present?
    @description = @author.primary_description
    @ranked_books = ranked_books.to_a
  end

  def all_books
    @indexable = false
    @ranked_item = author_ranked_item
    @pagy, @books = pagy_path(all_books_relation, limit: 50)
  end

  private

  # find_by!(slug:), never friendly.find: Books::Author uses friendly_id with
  # :finders, which resolves slugs before primary keys.
  def load_author
    @author = Books::Author.find_by!(slug: params[:slug])
  end

  def author_ranked_item
    config = Books::Authors::RankingConfiguration.default_primary
    return nil if config.nil?

    config.ranked_items.where.not(rank: nil).find_by(item: @author)
  end

  def ranked_books
    return Books::Book.none if @ranking_configuration.nil?

    @author.books
      .joins(
        "JOIN ranked_items ON ranked_items.item_id = books_books.id " \
        "AND ranked_items.item_type = 'Books::Book' " \
        "AND ranked_items.ranking_configuration_id = #{@ranking_configuration.id.to_i}"
      )
      .where.not(ranked_items: {rank: nil})
      .select("books_books.*, ranked_items.rank AS ranked_position")
      .preload(primary_image: {file_attachment: :blob})
      .order(Arel.sql("ranked_items.rank ASC"))
  end

  def all_books_relation
    @author.books
      .preload(primary_image: {file_attachment: :blob})
      .order(Arel.sql("books_books.first_published_year ASC NULLS LAST"), :title)
  end
end
