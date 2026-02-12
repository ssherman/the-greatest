class Admin::Music::ListsController < Admin::ListsBaseController
  layout "music/admin"

  private

  # Override to allow domain-scoped access for music domain
  def authenticate_admin!
    return if current_user&.admin? || current_user&.editor?

    unless current_user&.can_access_domain?("music")
      redirect_to domain_root_path, alert: "Access denied. You need permission for music admin."
    end
  end

  def policy_class
    Music::ListPolicy
  end

  def item_label
    "Album"
  end

  def permitted_params
    super + [:musicbrainz_series_id]
  end
end
