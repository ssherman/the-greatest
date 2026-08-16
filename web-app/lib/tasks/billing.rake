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

  desc "Report the legacy -> new billing migration invariants"
  task verify_migration: :environment do
    result = Services::Billing::VerifyMigration.call
    data = result.data

    puts "Legacy subscriptions with no membership: #{data[:missing_subscriptions].size}"
    data[:missing_subscriptions].each { |id| puts "  #{id}" }

    puts "Paid users with no legacy grant: #{data[:missing_grants].size}"
    data[:missing_grants].each { |id| puts "  user #{id}" }

    puts "Legacy donations not imported: #{data[:missing_donations].size}"
    data[:missing_donations].each { |id| puts "  #{id}" }

    puts "Early supporters who also pay through Stripe: #{data[:overlap_user_ids].size}"
    puts "  #{data[:overlap_user_ids].join(", ")}" if data[:overlap_user_ids].any?

    # Informational, never a failure: an unmappable customer is an outcome the
    # design expects. Attach these by hand at /admin/memberships?attached=false.
    puts "Unattached memberships: #{data[:unattached].size}"
    data[:unattached].each do |row|
      puts "  ##{row[:id]} #{row[:stripe_customer_id]} #{row[:stripe_subscription_id]} #{row[:status]}"
    end

    unless result.success?
      warn "FAILED: #{result.errors.join("; ")}"
      exit 1
    end
    puts "All invariants hold."
  end
end
