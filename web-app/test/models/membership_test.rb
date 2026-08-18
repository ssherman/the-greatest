# frozen_string_literal: true

require "test_helper"

# == Schema Information
#
# Table name: memberships
#
#  id                     :bigint           not null, primary key
#  cancel_at_period_end   :boolean          default(FALSE), not null
#  canceled_at            :datetime
#  current_period_end     :datetime
#  ended_email_sent_at    :datetime
#  interval               :integer
#  note                   :text
#  origin_domain          :string
#  source                 :integer          default(0), not null
#  status                 :integer          not null
#  stripe_synced_at       :datetime
#  welcome_email_sent_at  :datetime
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  granted_by_id          :bigint
#  stripe_customer_id     :string
#  stripe_subscription_id :string
#  user_id                :bigint
#
# Indexes
#
#  index_memberships_on_granted_by_id               (granted_by_id)
#  index_memberships_on_stripe_customer_id          (stripe_customer_id)
#  index_memberships_on_stripe_subscription_id      (stripe_subscription_id) UNIQUE WHERE (stripe_subscription_id IS NOT NULL)
#  index_memberships_on_user_id                     (user_id)
#  index_memberships_on_user_id_and_status          (user_id,status)
#  index_memberships_one_grant_per_user_per_source  (user_id,source) UNIQUE WHERE ((source <> 0) AND (user_id IS NOT NULL))
#
# Foreign Keys
#
#  fk_rails_...  (granted_by_id => users.id)
#  fk_rails_...  (user_id => users.id)
#
class MembershipTest < ActiveSupport::TestCase
  test "a stripe membership is valid" do
    membership = Membership.new(
      user: users(:regular_user), source: :stripe, status: :active, interval: :monthly,
      stripe_subscription_id: "sub_new", stripe_customer_id: "cus_new",
      current_period_end: 1.month.from_now
    )
    assert membership.valid?, membership.errors.full_messages.join(", ")
  end

  test "a comped membership needs no stripe ids and no end date" do
    membership = Membership.new(
      user: users(:regular_user), source: :comped, status: :active,
      note: "Contributor", granted_by: users(:admin_user)
    )
    assert membership.valid?, membership.errors.full_messages.join(", ")
  end

  test "a membership may have no user" do
    membership = Membership.new(
      source: :stripe, status: :active, interval: :monthly,
      stripe_subscription_id: "sub_orphan", stripe_customer_id: "cus_orphan"
    )
    assert membership.valid?, membership.errors.full_messages.join(", ")
  end

  test "stripe_subscription_id is unique" do
    existing = memberships(:regular_user_monthly)
    duplicate = Membership.new(
      user: users(:editor_user), source: :stripe, status: :active, interval: :monthly,
      stripe_subscription_id: existing.stripe_subscription_id
    )
    refute duplicate.valid?
    assert_includes duplicate.errors[:stripe_subscription_id], "has already been taken"
  end

  test "many memberships may have a null stripe_subscription_id" do
    # Two different users, not two rows for one user: the one-grant-per-user
    # index caps a single user at one comped row, so this must vary the user
    # to exercise the null-uniqueness behavior it's actually testing.
    Membership.create!(user: users(:regular_user), source: :comped, status: :active, note: "comp 0")
    Membership.create!(user: users(:google_user), source: :comped, status: :active, note: "comp 1")
    assert_operator Membership.where(stripe_subscription_id: nil).count, :>=, 2
  end

  test "a stripe membership requires a subscription id" do
    membership = Membership.new(user: users(:regular_user), source: :stripe, status: :active)
    refute membership.valid?
    assert_includes membership.errors[:stripe_subscription_id], "can't be blank"
  end

  test "stripe? distinguishes reconcilable rows from manual grants" do
    assert memberships(:regular_user_monthly).stripe?
    refute memberships(:editor_user_comped).stripe?
    refute memberships(:password_user_legacy).stripe?
  end

  test "a comped membership may not carry a stripe_subscription_id" do
    membership = Membership.new(
      user: users(:contractor_user), source: :comped, status: :active,
      stripe_subscription_id: "sub_should_not_be_here"
    )
    assert_not membership.valid?
    assert membership.errors.of_kind?(:stripe_subscription_id, :present)
  end

  test "a legacy membership may not carry a stripe_subscription_id" do
    membership = Membership.new(
      user: users(:contractor_user), source: :legacy, status: :active,
      stripe_subscription_id: "sub_should_not_be_here"
    )
    assert_not membership.valid?
  end

  test "a stripe membership still requires a stripe_subscription_id" do
    membership = Membership.new(user: users(:contractor_user), source: :stripe, status: :active)
    assert_not membership.valid?
    assert membership.errors.of_kind?(:stripe_subscription_id, :blank)
  end

  test "a second comped membership for the same user is rejected by the database" do
    # editor_user already holds editor_user_comped.
    assert_raises(ActiveRecord::RecordNotUnique) do
      Membership.new(user: users(:editor_user), source: :comped, status: :active).save(validate: false)
    end
  end

  test "a user may hold both a legacy grant and a comp" do
    Membership.create!(user: users(:contractor_user), source: :legacy, status: :active)
    membership = Membership.new(user: users(:contractor_user), source: :comped, status: :active)
    assert membership.save, membership.errors.full_messages.to_sentence
  end

  test "a user may hold two stripe memberships" do
    membership = Membership.new(
      user: users(:regular_user), source: :stripe, status: :active,
      stripe_subscription_id: "sub_regular_second", stripe_customer_id: "cus_regular"
    )
    assert membership.save, membership.errors.full_messages.to_sentence
  end

  test "two unattached comped rows are allowed" do
    Membership.create!(user: nil, source: :comped, status: :active)
    membership = Membership.new(user: nil, source: :comped, status: :active)
    assert membership.save, membership.errors.full_messages.to_sentence
  end

  test "granting_access includes an active stripe membership" do
    assert_includes Membership.granting_access, memberships(:regular_user_monthly)
  end

  test "granting_access includes a trialing stripe membership" do
    # The load-bearing line: granting_access's WHERE lists status: [:active,
    # :trialing]. Deleting :trialing from that array leaves the rest of the
    # suite green with no other fixture at status: 0 (trialing) -- this
    # fixture and assertion exist specifically to make that deletion visible.
    assert_includes Membership.granting_access, memberships(:contractor_user_trialing)
  end

  test "granting_access includes a canceled stripe membership still inside its paid period" do
    assert_includes Membership.granting_access, memberships(:google_user_canceled_in_grace)
  end

  test "granting_access excludes a canceled stripe membership past its paid period" do
    refute_includes Membership.granting_access, memberships(:canceled_and_expired)
  end

  test "granting_access excludes a past_due stripe membership even with a future period end" do
    # The date is deliberately in the future: this asserts the STATUS is what
    # denies access, not the date. A scope that only checked the date would pass
    # every other test in this file and fail this one.
    refute_includes Membership.granting_access, memberships(:regular_user_past_due)
  end

  test "granting_access includes a comped membership with no end date" do
    assert_includes Membership.granting_access, memberships(:editor_user_comped)
  end

  test "granting_access includes a legacy early-supporter membership" do
    assert_includes Membership.granting_access, memberships(:password_user_legacy)
  end

  test "granting_access excludes a comped membership whose end date has passed" do
    refute_includes Membership.granting_access, memberships(:comped_expired)
  end

  test "granting_access ignores the date for an active stripe membership" do
    # Trust Stripe's status over our copy of the date: a stale current_period_end
    # must not deny a subscriber who is currently paying.
    membership = memberships(:regular_user_monthly)
    membership.update!(current_period_end: 5.days.ago)

    assert_includes Membership.granting_access, membership
  end
end
