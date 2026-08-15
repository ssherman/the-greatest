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
    events.find_each { |event| Billing::ProcessStripeEventJob.perform_async(event.id) }
  end
end
