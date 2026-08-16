# Display-field editing only.
#
# stripe_price_id, stripe_lookup_key, amount_cents, key, kind and interval are
# owned by `rake stripe:sync_plans`, which resolves them from the current
# environment's Stripe account. A hand-edited price id is a silent way to charge
# the wrong amount, or to charge through someone else's price -- so the form
# shows those fields and permits none of them.
class Admin::BillingPlansController < Admin::BaseController
  before_action :require_admin_role!
  before_action :set_plan, only: [:edit, :update]

  def index
    @plans = BillingPlan.order(:position, :id)
  end

  def edit
  end

  def update
    if @plan.update(plan_params)
      redirect_to admin_billing_plans_path, notice: "Plan updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def set_plan
    @plan = BillingPlan.find(params[:id])
  end

  def plan_params
    # .expect, not .require(...).permit(...): a scalar body (billing_plan=x)
    # makes params[:billing_plan] a String, and .permit on a String is a
    # NoMethodError -> 500. .expect raises ParameterMissing for the wrong
    # shape too, which Rails renders as 400. Permitted-key behaviour is
    # unchanged; verified in the forgery tests below.
    params.expect(billing_plan: [:name, :position, :active])
  end
end
