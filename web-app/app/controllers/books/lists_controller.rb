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
end
