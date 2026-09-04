# == Schema Information
#
# Table name: subscriptions
#
#  id                     :bigint           not null, primary key
#  current_period_end     :datetime
#  email_sent             :boolean
#  status                 :integer          not null
#  subscription_type      :integer          not null
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  stripe_subscription_id :string
#  user_id                :bigint           not null
#
# Indexes
#
#  index_subscriptions_on_stripe_subscription_id  (stripe_subscription_id) UNIQUE
#  index_subscriptions_on_user_id                 (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
module LegacyBooks
  # Read for verification only. The legacy subscriptions table is deliberately
  # NOT migrated -- it was written by the handler this subsystem replaces and is
  # the least trustworthy copy of the data. Stripe is the source of truth, and
  # billing:reconcile_all already rebuilt every membership from it. This model
  # exists so verify_migration can ask "is every subscription legacy knew about
  # accounted for?" without importing any of it.
  class Subscription < Record
    self.table_name = "subscriptions"
  end
end
