class Admin::Music::CategoriesController < Admin::CategoriesBaseController
  include Admin::DomainScopedAuth

  protected

  def model_class = Music::Category
  def param_key = :music_category
  def category_path(category) = admin_category_path(category)
  def categories_path = admin_categories_path
  def new_category_path = new_admin_category_path
  def edit_category_path(category) = edit_admin_category_path(category)
  def domain_label = "Music"
  def subtitle = "Manage music genres, locations, and subjects"

  def load_show_stats
    @stats = {
      "Albums" => @category.albums.count,
      "Artists" => @category.artists.count,
      "Songs" => @category.songs.count
    }
  end
end
