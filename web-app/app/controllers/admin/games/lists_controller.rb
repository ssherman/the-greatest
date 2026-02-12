class Admin::Games::ListsController < Admin::ListsBaseController
  layout "games/admin"

  private

  # Override to allow domain-scoped access for games domain
  def authenticate_admin!
    return if current_user&.admin? || current_user&.editor?

    unless current_user&.can_access_domain?("games")
      redirect_to domain_root_path, alert: "Access denied. You need permission for games admin."
    end
  end

  def policy_class
    Games::ListPolicy
  end

  def item_label
    "Game"
  end

  protected

  def list_class
    ::Games::List
  end

  def lists_path
    admin_games_lists_path
  end

  def list_path(list)
    admin_games_list_path(list)
  end

  def new_list_path
    new_admin_games_list_path
  end

  def edit_list_path(list)
    edit_admin_games_list_path(list)
  end

  def param_key
    :games_list
  end

  def items_count_name
    "games_count"
  end

  def listable_includes
    [:companies, :platforms, :series]
  end
end
