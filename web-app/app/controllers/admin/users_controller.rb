class Admin::UsersController < Admin::BaseController
  layout "music/admin"
  before_action :require_admin_role!
  before_action :set_user, only: [:show, :edit, :update, :destroy]

  def index
    @users = User.all
    @users = @users.where("email ILIKE ?", "%#{params[:q]}%") if params[:q].present?
    @users = @users.order(created_at: :desc)

    @pagy, @users = pagy(@users, items: 25)
  end

  def show
  end

  def edit
  end

  def update
    if @user.update(user_params)
      redirect_to admin_user_path(@user), notice: "User updated successfully."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @user.destroy!
    redirect_to admin_users_path, notice: "User deleted successfully."
  end

  private

  def require_admin_role!
    unless current_user&.admin?
      redirect_to domain_root_path, alert: "Access denied. Admin role required."
    end
  end

  def set_user
    @user = User.find(params[:id])
  end

  def user_params
    params.require(:user).permit(:email, :display_name, :name, :role, :stripe_customer_id)
  end
end
