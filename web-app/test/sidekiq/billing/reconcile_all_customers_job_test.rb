# frozen_string_literal: true

require "test_helper"

module Billing
  class ReconcileAllCustomersJobTest < ActiveSupport::TestCase
    test "logs a summary and does not raise when the sweep succeeds" do
      Services::Billing::ReconcileAllCustomers.expects(:call).returns(
        Services::Billing::ReconcileAllCustomers::Result.new(
          success?: true,
          data: {customers: 3, reconciled: 2, failed: ["cus_bad"]},
          errors: []
        )
      )

      assert_nothing_raised { ReconcileAllCustomersJob.new.perform }
    end

    # The raise is what makes Sidekiq retry the nightly sweep. Softening it to a
    # log-only failure would silently disable recovery after an outage longer than
    # Stripe's 72-hour retry window -- which is the one thing this job exists to
    # provide, and the failure nobody would notice until they needed it.
    test "raises when the sweep itself fails so Sidekiq retries" do
      Services::Billing::ReconcileAllCustomers.expects(:call).returns(
        Services::Billing::ReconcileAllCustomers::Result.new(
          success?: false, data: nil, errors: ["account listing down"]
        )
      )

      error = assert_raises(RuntimeError) { ReconcileAllCustomersJob.new.perform }
      assert_match(/account listing down/, error.message)
    end
  end
end
