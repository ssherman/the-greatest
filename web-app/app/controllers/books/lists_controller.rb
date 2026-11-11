class Books::ListsController < PublicListsController
  layout "books/application"

  def self.ranking_configuration_class
    Books::RankingConfiguration
  end

  def self.lists_query_class
    Books::ListsQuery
  end

  def show
    @list = Books::List.where(status: :active).find_by!(id: params[:id])
    @ranked_list = @ranking_configuration.ranked_lists.find_by(list: @list)
    @indexable = @ranked_list.present?

    @pagy, @list_items = pagy_path(
      @list.list_items
        .includes(listable: [{book_authors: :author}, {primary_image: {file_attachment: :blob}}])
        .order(Arel.sql("list_items.position ASC NULLS LAST, list_items.id ASC")),
      limit: 100
    )
  end

  # 302, not 301: the id is per-database, and a browser holds a 301 forever.
  def users_favorites
    redirect_to books_list_path(users_favorites_list_id)
  end

  def legacy_users_favorites
    redirect_to books_list_path(users_favorites_list_id), status: :moved_permanently
  end

  private

  def users_favorites_list_id
    Books::List.generated_user_favorites.where(status: :active).pick(:id) ||
      raise(ActiveRecord::RecordNotFound)
  end
end
