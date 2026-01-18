class Admin::DomainRolesController < Admin::BaseController
  layout "music/admin"
  before_action :require_admin_role!
  before_action :set_user
  before_action :set_domain_role, only: [:update, :destroy]

  def index
    @domain_roles = @user.domain_roles.order(:domain)
    @available_domains = DomainRole.domains.keys - @domain_roles.map(&:domain)
  end

  def create
    @domain_role = @user.domain_roles.build(domain_role_params)

    if @domain_role.save
      redirect_to admin_user_domain_roles_path(@user), notice: "Domain role granted successfully."
    else
      redirect_to admin_user_domain_roles_path(@user), alert: "Failed to grant role: #{@domain_role.errors.full_messages.join(", ")}"
    end
  end

  def update
    if @domain_role.update(domain_role_params)
      redirect_to admin_user_domain_roles_path(@user), notice: "Domain role updated successfully."
    else
      redirect_to admin_user_domain_roles_path(@user), alert: "Failed to update role: #{@domain_role.errors.full_messages.join(", ")}"
    end
  end

  def destroy
    @domain_role.destroy!
    redirect_to admin_user_domain_roles_path(@user), notice: "Domain role revoked successfully."
  end

  private

  def set_user
    @user = User.find(params[:user_id])
  end

  def set_domain_role
    @domain_role = @user.domain_roles.find(params[:id])
  end

  def domain_role_params
    params.require(:domain_role).permit(:domain, :permission_level)
  end
end
