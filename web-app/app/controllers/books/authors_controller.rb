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
    @indexable = @ranked_item.present? && !@author.provisional?
    @description = @author.primary_description
    @ranked_books = Books::AuthorBooksQuery.call(author: @author, ranking_configuration: @ranking_configuration, ranked_only: true).to_a
  end

  def all_books
    @indexable = false
    @ranked_item = author_ranked_item
    @description = @author.primary_description
    @pagy, @books = pagy_path(Books::AuthorBooksQuery.call(author: @author, ranking_configuration: @ranking_configuration), limit: 50)
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
end
