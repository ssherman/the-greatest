# frozen_string_literal: true

require "test_helper"

# == Schema Information
#
# Table name: donations
#
#  id                         :bigint           not null, primary key
#  amount_cents               :integer          not null
#  currency                   :string           default("usd"), not null
#  domain                     :string
#  email                      :string
#  status                     :integer          default(0), not null
#  created_at                 :datetime         not null
#  updated_at                 :datetime         not null
#  stripe_checkout_session_id :string
#  stripe_payment_intent_id   :string
#  user_id                    :bigint
#
# Indexes
#
#  index_donations_on_stripe_payment_intent_id  (stripe_payment_intent_id) UNIQUE WHERE (stripe_payment_intent_id IS NOT NULL)
#  index_donations_on_user_id                   (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
class DonationTest < ActiveSupport::TestCase
  test "a donation is valid without a user" do
    donation = Donation.new(amount_cents: 2500, status: :succeeded,
      stripe_payment_intent_id: "pi_anon", email: "anon@example.com")
    assert donation.valid?, donation.errors.full_messages.join(", ")
  end

  test "amount_cents must be positive" do
    donation = Donation.new(amount_cents: 0, status: :succeeded,
      stripe_payment_intent_id: "pi_zero")
    refute donation.valid?
    assert_includes donation.errors[:amount_cents], "must be greater than 0"
  end

  test "stripe_payment_intent_id is unique" do
    duplicate = Donation.new(amount_cents: 500, status: :succeeded,
      stripe_payment_intent_id: donations(:regular_user_gift).stripe_payment_intent_id)
    refute duplicate.valid?
    assert_includes duplicate.errors[:stripe_payment_intent_id], "has already been taken"
  end

  # Guards `allow_nil: true` on the uniqueness validator. Rails' uniqueness check
  # does NOT skip nil by default, so without allow_nil the second of these becomes
  # invalid with "has already been taken". A pending donation legitimately has no
  # payment intent id until Stripe creates one, so more than one must be able to
  # sit in that state at once.
  test "two donations may both have a nil stripe_payment_intent_id" do
    first = Donation.new(amount_cents: 500, status: :pending, email: "first@example.com")
    assert first.valid?, first.errors.full_messages.join(", ")
    first.save!

    second = Donation.new(amount_cents: 900, status: :pending, email: "second@example.com")
    assert second.valid?, second.errors.full_messages.join(", ")
  end

  test "amount_in_dollars converts cents" do
    assert_equal 25.0, donations(:regular_user_gift).amount_in_dollars
  end

  test "successful scope returns only succeeded donations" do
    assert_includes Donation.successful, donations(:regular_user_gift)
    refute_includes Donation.successful, donations(:failed_attempt)
  end
end
