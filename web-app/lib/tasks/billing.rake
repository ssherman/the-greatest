# frozen_string_literal: true

namespace :billing do
  desc "Reconcile every Stripe customer against local membership rows"
  task reconcile_all: :environment do
    result = Services::Billing::ReconcileAllCustomers.call

    if result.success?
      puts "Customers seen:  #{result.data[:customers]}"
      puts "Reconciled:      #{result.data[:reconciled]}"
      puts "Failed:          #{result.data[:failed].size}"
      result.data[:failed].each { |id| puts "  #{id}" }
    else
      warn "Sweep failed: #{result.errors.join("; ")}"
      exit 1
    end
  end

  desc "Re-enqueue every stripe_event left in the failed state"
  task replay_failed: :environment do
    events = StripeEvent.failed.order(:stripe_created_at)
    puts "Re-enqueuing #{events.count} failed events"
    # .each, not .find_each: find_each silently ignores a custom .order and batches
    # by primary key, so oldest-first would not actually be honoured. This is a
    # bounded error queue, so loading it is fine. Order is not required for
    # correctness -- reconciliation converges regardless of delivery order -- but
    # oldest-first makes a replay far easier to follow.
    events.each { |event| Billing::ProcessStripeEventJob.perform_async(event.id) }
  end
end
