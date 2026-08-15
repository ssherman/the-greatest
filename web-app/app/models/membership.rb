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
#  index_memberships_on_granted_by_id           (granted_by_id)
#  index_memberships_on_stripe_customer_id      (stripe_customer_id)
#  index_memberships_on_stripe_subscription_id  (stripe_subscription_id) UNIQUE WHERE (stripe_subscription_id IS NOT NULL)
#  index_memberships_on_user_id                 (user_id)
#  index_memberships_on_user_id_and_status      (user_id,status)
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

  # True when the reconciler owns this row. Reads better at call sites than
  # source_stripe? and gives a single place to change the rule.
  def stripe? = source_stripe?
end
