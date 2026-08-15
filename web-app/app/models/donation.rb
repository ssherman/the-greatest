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
# frozen_string_literal: true

# A one-time payment. Recorded from checkout.session.completed in payment mode,
# and imported from the legacy books database for history.
#
# amount_cents is named for its unit on purpose: the legacy column was `amount`,
# which needed an amount_in_dollars helper to disambiguate at every call site.
class Donation < ApplicationRecord
  belongs_to :user, optional: true

  enum :status, {pending: 0, succeeded: 1, failed: 2, refunded: 3}

  validates :amount_cents, presence: true, numericality: {greater_than: 0}
  validates :status, presence: true
  validates :stripe_payment_intent_id, uniqueness: true, allow_nil: true

  scope :successful, -> { where(status: :succeeded) }
  scope :recent, -> { order(created_at: :desc) }

  def amount_in_dollars = amount_cents / 100.0
end
