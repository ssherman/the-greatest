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
# frozen_string_literal: true

# The single source of truth for "is this person a member?".
#
# Replaces the legacy app's Subscription model *and* its users.paid boolean.
# A comped membership is a row with source: :comped and no Stripe ids, which is
# what makes it structurally unreachable from the reconciler — that only ever
# touches source: :stripe rows.
#
# CALLER WARNING -- the uniqueness/partial-index trap. `validates
# :stripe_subscription_id, uniqueness: true, allow_nil: true` runs a SELECT
# before the INSERT, so an ordinary duplicate raises RecordInvalid, NOT
# RecordNotUnique; the database constraint only fires when two writers race
# past the SELECT. A caller that needs to tell "already taken" from any other
# validation failure must rescue BOTH and narrow the RecordInvalid branch with
# `e.record.errors.of_kind?(:stripe_subscription_id, :taken)`, exactly as
# Webhooks::StripeController#record_event does for StripeEvent. Rescuing
# RecordInvalid broadly here would silently swallow an unrelated failure.
#
# The (user_id, source) index added alongside the absence validation below is
# NOT mirrored by a model validation, deliberately: it exists to make the comp
# and legacy-import write paths idempotent, and those paths use
# find_or_initialize_by, so they never generate a duplicate in normal
# operation. A caller that can race must rescue RecordNotUnique.
class Membership < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :granted_by, class_name: "User", optional: true

  enum :source, {stripe: 0, comped: 1, legacy: 2}, prefix: true
  enum :status, {
    trialing: 0, active: 1, canceled: 2, incomplete: 3,
    incomplete_expired: 4, past_due: 5, unpaid: 6, paused: 7
  }
  enum :interval, {monthly: 0, yearly: 1}, prefix: true

  validates :source, presence: true
  validates :status, presence: true
  validates :stripe_subscription_id, uniqueness: true, allow_nil: true
  validates :stripe_subscription_id, presence: true, if: :source_stripe?
  # The other direction, and the reason the spec's "a comped membership is
  # structurally unreachable from the reconciler" is a guarantee rather than an
  # aspiration. ReconcileCustomer finds rows by stripe_subscription_id, so a
  # manual grant that cannot hold one can never be found -- the defensive
  # `return unless membership.stripe?` guard in ReconcileCustomer#upsert is now
  # belt to this braces, not the only thing standing between a webhook and an
  # admin's decision.
  validates :stripe_subscription_id, absence: true, unless: :source_stripe?

  # True when the reconciler owns this row. Reads better at call sites than
  # source_stripe? and gives a single place to change the rule.
  def stripe? = source_stripe?
end
