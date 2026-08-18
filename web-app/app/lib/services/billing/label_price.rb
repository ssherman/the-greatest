# frozen_string_literal: true

module Services
  module Billing
    # Writes a lookup_key onto an existing Stripe price.
    #
    # This is how the two LIVE membership prices -- the ones the legacy books app
    # already sells through -- become resolvable by SyncPlans. A lookup key is a
    # label: it does not change the amount, the billing interval, or anything
    # about an existing subscriber. The Result reports the amount either side of
    # the change so that is verifiable rather than merely asserted.
    #
    # transfer_lookup_key is deliberately NOT passed. Without it, Stripe refuses
    # when the key is already on another price; with it, Stripe would silently
    # move the key, and a production checkout would start pointing at whatever
    # price inherited it.
    class LabelPrice
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(price_id:, lookup_key:) = new(price_id: price_id, lookup_key: lookup_key).call

      def initialize(price_id:, lookup_key:)
        @price_id = price_id
        @lookup_key = lookup_key
      end

      def call
        return failure("price_id is required") if @price_id.blank?
        return failure("lookup_key is required") if @lookup_key.blank?

        before = ::Stripe::Price.retrieve(@price_id)
        after = ::Stripe::Price.update(@price_id, lookup_key: @lookup_key)

        Result.new(
          success?: true,
          data: {
            price_id: after.id,
            before: before.lookup_key,
            after: after.lookup_key,
            unit_amount: after.unit_amount,
            currency: after.currency,
            active: after.active
          },
          errors: []
        )
      rescue ::Stripe::StripeError => e
        Rails.logger.error("[billing] labelling #{@price_id} failed: #{e.class}")
        failure(e.message)
      end

      private

      def failure(message) = Result.new(success?: false, data: nil, errors: [message])
    end
  end
end
