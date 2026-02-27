class Admin::Games::CategoriesController < Admin::CategoriesBaseController
  layout "games/admin"

  private

  def authenticate_admin!
    return if current_user&.admin? || current_user&.editor?

    unless current_user&.can_access_domain?("games")
      redirect_to domain_root_path, alert: "Access denied. You need permission for games admin."
    end
  end

  protected

  def model_class = Games::Category
  def param_key = :games_category
  def category_path(category) = admin_games_category_path(category)
  def categories_path = admin_games_categories_path
  def new_category_path = new_admin_games_category_path
  def edit_category_path(category) = edit_admin_games_category_path(category)
  def domain_label = "Games"
  def subtitle = "Manage game genres, locations, and subjects"

  def load_show_stats
    @stats = {
      "Games" => @category.games.count
    }
  end
end
