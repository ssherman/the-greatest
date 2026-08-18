# frozen_string_literal: true

namespace :stripe do
  desc "Create membership and donation products/prices in a SANDBOX and seed billing_plans"
  task bootstrap: :environment do
    result = Services::Billing::BootstrapPlans.call

    unless result.success?
      warn "FAILED: #{result.errors.join("; ")}"
      exit 1
    end

    puts "Sandbox bootstrapped:"
    result.data.each { |plan| puts "  #{plan.key.ljust(10)} #{plan.stripe_price_id}  (#{plan.stripe_lookup_key})" }
  end

  desc "Re-resolve every billing_plan's Stripe price from its lookup key"
  task sync_plans: :environment do
    result = Services::Billing::SyncPlans.call

    result.data[:resolved].each { |key| puts "resolved #{key}" }

    unless result.success?
      warn "FAILED to resolve: #{result.data[:failures].join(", ")}"
      warn "Each membership plan needs its lookup_key written onto the live price first:"
      warn "  CONFIRM=label-price bin/rails 'stripe:label_price[price_xxx,membership_monthly]'"
      exit 1
    end

    puts "All plans resolved."
  end

  desc "Write a lookup_key onto an existing Stripe price: stripe:label_price[price_id,lookup_key]"
  task :label_price, [:price_id, :lookup_key] => :environment do |_t, args|
    unless ENV["CONFIRM"] == "label-price"
      warn "REFUSING: re-run with CONFIRM=label-price to write a lookup key onto a live price."
      warn "This is a label-only change -- it does not affect the amount, the billing"
      warn "interval, or any existing subscriber -- but it does write to the live account."
      exit 1
    end

    result = Services::Billing::LabelPrice.call(price_id: args[:price_id], lookup_key: args[:lookup_key])

    unless result.success?
      warn "FAILED: #{result.errors.join("; ")}"
      exit 1
    end

    puts "price:      #{result.data[:price_id]}"
    puts "lookup_key: #{result.data[:before].inspect} -> #{result.data[:after].inspect}"
    puts "amount:     #{result.data[:unit_amount]} #{result.data[:currency]} (unchanged), active=#{result.data[:active]}"
  end

  desc "Create the custom-amount donation price (safe in livemode: purely additive)"
  task create_donation_price: :environment do
    unless ENV["CONFIRM"] == "create-donation-price"
      warn "REFUSING: re-run with CONFIRM=create-donation-price."
      exit 1
    end

    result = Services::Billing::CreateDonationPrice.call

    unless result.success?
      warn "FAILED: #{result.errors.join("; ")}"
      exit 1
    end

    puts "price: #{result.data.id}  (lookup_key #{result.data.lookup_key})"
    puts "Now run: bin/rails stripe:sync_plans"
  end
end
