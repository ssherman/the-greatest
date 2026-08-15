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
# frozen_string_literal: true

# The price catalogue, replacing the legacy app's config/stripe_products.yml.
#
# Price ids differ between the Stripe sandbox and the production account, which
# is exactly why that YAML file needed a hand-edited per-environment block. As
# database rows, each environment simply holds its own ids, and
# `rake stripe:sync_plans` re-resolves them from stripe_lookup_key.
class BillingPlan < ApplicationRecord
  enum :kind, {membership: 0, donation: 1}, prefix: true
  enum :interval, {monthly: 0, yearly: 1}, prefix: true

  validates :key, presence: true, uniqueness: true
  validates :name, presence: true
  validates :stripe_price_id, presence: true, uniqueness: true
  validates :kind, presence: true

  scope :active, -> { where(active: true).order(:position) }
  scope :membership, -> { where(kind: :membership).order(:position) }

  def self.donation_price = find_by(kind: :donation, active: true)

  def amount_in_dollars = amount_cents && amount_cents / 100.0
end
