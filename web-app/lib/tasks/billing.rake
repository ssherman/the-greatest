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

  desc "Mark every existing membership as already-emailed, before opening MEMBERSHIP_EMAIL_SCOPE"
  task backfill_email_stamps: :environment do
    result = Services::Billing::BackfillEmailStamps.call
    puts "welcome stamps filled: #{result.data[:welcome]}"
    puts "ended stamps filled:   #{result.data[:ended]}"
  end

  desc "Report the legacy -> new billing migration invariants"
  task verify_migration: :environment do
    result = Services::Billing::VerifyMigration.call
    data = result.data

    puts "Legacy subscriptions with no membership: #{data[:missing_subscriptions].size}"
    data[:missing_subscriptions].each { |id| puts "  #{id}" }

    puts "Paid users with no legacy grant: #{data[:missing_grants].size}"
    data[:missing_grants].each { |id| puts "  user #{id}" }

    # Never fails the run: these legacy users have no row in the new `users`
    # table at all, which is exactly what MembershipMigrator is designed to
    # skip. This is expected drift from the live legacy database, not a
    # billing problem -- do not investigate it as one.
    puts "Legacy paid users not yet migrated to the new users table (expected drift, not a billing problem): #{data[:unmigrated_users].size}"
    if data[:unmigrated_users].any?
      puts "  Remedy: run data_migration:users, then re-run this task."
      data[:unmigrated_users].each { |id| puts "  legacy user #{id}" }
    end

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
