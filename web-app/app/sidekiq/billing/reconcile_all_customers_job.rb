# frozen_string_literal: true

module Billing
  # Nightly drift check. Logs a summary so a divergence between local rows and
  # Stripe shows up in the log rather than in a support email.
  class ReconcileAllCustomersJob
    include Sidekiq::Job

    def perform
      result = Services::Billing::ReconcileAllCustomers.call

      if result.success?
        Rails.logger.info(
          "[billing] nightly sweep: #{result.data[:reconciled]}/#{result.data[:customers]} " \
          "customers reconciled, failed=#{result.data[:failed].inspect}"
        )
      else
        Rails.logger.error("[billing] nightly sweep failed: #{result.errors.join("; ")}")
        raise result.errors.join("; ")
      end
    end
  end
end
