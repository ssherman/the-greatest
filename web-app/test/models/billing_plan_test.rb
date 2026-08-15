# frozen_string_literal: true

require "test_helper"

# == Schema Information
#
# Table name: billing_plans
#
#  id                :bigint           not null, primary key
#  active            :boolean          default(TRUE), not null
#  amount_cents      :integer
#  currency          :string           default("usd"), not null
#  interval          :integer
#  key               :string           not null
#  kind              :integer          not null
#  name              :string           not null
#  position          :integer          default(0), not null
#  stripe_lookup_key :string
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  stripe_price_id   :string           not null
#
# Indexes
#
#  index_billing_plans_on_key              (key) UNIQUE
#  index_billing_plans_on_stripe_price_id  (stripe_price_id) UNIQUE
#
class BillingPlanTest < ActiveSupport::TestCase
  test "key is unique" do
    duplicate = BillingPlan.new(kind: :membership, key: "monthly", name: "Dupe",
      stripe_price_id: "price_dupe")
    refute duplicate.valid?
    assert_includes duplicate.errors[:key], "has already been taken"
  end

  test "stripe_price_id is unique" do
    duplicate = BillingPlan.new(kind: :membership, key: "other", name: "Other",
      stripe_price_id: billing_plans(:monthly).stripe_price_id)
    refute duplicate.valid?
    assert_includes duplicate.errors[:stripe_price_id], "has already been taken"
  end

  test "membership scope returns only membership plans in position order" do
    assert_equal %w[monthly yearly], BillingPlan.membership.active.pluck(:key)
  end

  test "donation_price returns the single donation plan" do
    assert_equal billing_plans(:donation), BillingPlan.donation_price
  end

  test "inactive plans are excluded from active" do
    refute_includes BillingPlan.active, billing_plans(:retired_monthly)
  end

  test "amount_in_dollars formats cents" do
    assert_equal 5.0, billing_plans(:monthly).amount_in_dollars
  end
end
