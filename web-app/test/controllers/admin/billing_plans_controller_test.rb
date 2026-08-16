require "test_helper"

class Admin::BillingPlansControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin_user)
    @editor = users(:editor_user)
    @plan = billing_plans(:monthly)
    host! Rails.application.config.domains[:music]
  end

  test "an admin sees the index" do
    sign_in_as(@admin, stub_auth: true)
    get admin_billing_plans_url
    assert_response :success
  end

  test "an editor is denied the index" do
    sign_in_as(@editor, stub_auth: true)
    get admin_billing_plans_url
    assert_response :redirect
  end

  test "a signed-out visitor is denied the index" do
    get admin_billing_plans_url
    assert_response :redirect
  end

  test "an admin edits the display fields" do
    sign_in_as(@admin, stub_auth: true)
    patch admin_billing_plan_url(@plan), params: {
      billing_plan: {name: "Monthly Supporter", position: 5, active: false}
    }
    @plan.reload
    assert_equal "Monthly Supporter", @plan.name
    assert_equal 5, @plan.position
    assert_equal false, @plan.active
    assert_redirected_to admin_billing_plans_url
  end

  test "the stripe price id cannot be changed through the form" do
    sign_in_as(@admin, stub_auth: true)
    patch admin_billing_plan_url(@plan), params: {
      billing_plan: {name: "Still fine", stripe_price_id: "price_attacker_owned"}
    }
    assert_equal "price_test_monthly", @plan.reload.stripe_price_id
  end

  test "the lookup key and amount cannot be changed through the form" do
    sign_in_as(@admin, stub_auth: true)
    patch admin_billing_plan_url(@plan), params: {
      billing_plan: {stripe_lookup_key: "attacker_key", amount_cents: 1, key: "hijacked"}
    }
    @plan.reload
    assert_equal "membership_monthly", @plan.stripe_lookup_key
    assert_equal 500, @plan.amount_cents
    assert_equal "monthly", @plan.key
  end

  test "an editor may not edit a plan" do
    sign_in_as(@editor, stub_auth: true)
    patch admin_billing_plan_url(@plan), params: {billing_plan: {name: "Nope"}}
    assert_equal "Monthly Membership", @plan.reload.name
  end

  test "an invalid name re-renders the form" do
    sign_in_as(@admin, stub_auth: true)
    patch admin_billing_plan_url(@plan), params: {billing_plan: {name: ""}}
    assert_response :unprocessable_entity
    assert_equal "Monthly Membership", @plan.reload.name
  end
end
