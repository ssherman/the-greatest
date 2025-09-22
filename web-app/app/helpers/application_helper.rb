module ApplicationHelper
  include Pagy::Frontend

  def current_user
    user_id = session[:user_id]
    return nil if user_id.blank?

    @current_user ||= User.find(user_id)
  end

  def signed_in?
    !!current_user
  end
end
