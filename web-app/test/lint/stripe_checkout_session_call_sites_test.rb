# frozen_string_literal: true

require "test_helper"

# Guardrail for the legacy books-app coexistence contract that
# Services::Billing::CreateCheckoutSession exists to hold (see
# docs/specs/membership-and-stripe-billing.md, "Legacy coexistence").
#
# This app shares one live Stripe account with the legacy books app for the
# next couple of months. Both receive every webhook event either one
# generates, and legacy's webhook guard decides "not mine, skip" partly by a
# STRUCTURAL test: a checkout.session.completed with a blank payment_link is
# assumed to be this app's, because legacy has never called
# Checkout::Session.create -- it sells only through Payment Links, and Stripe
# stamps a payment_link id on every session those produce.
#
# Two rules keep that guard reliable, and both are the kind of regression a
# unit test cannot see: a NEW call site added anywhere else in the app,
# outside the one file reviewed for this contract.
#
#   1. Nothing in this app may ever create a Stripe Payment Link. If it did,
#      sessions made through it would carry a payment_link id, legacy's
#      structural guard would never fire, and the donation defect that guard
#      closes would silently re-open: legacy would write a books-branded
#      donation row and email a books receipt for a donation made on another
#      domain. Nothing else in either codebase would catch it.
#   2. Exactly one call site may create a Checkout Session:
#      Services::Billing::CreateCheckoutSession. Every legacy-coexistence
#      metadata tag (origin_app, subscription_data[metadata]) is applied
#      there; a second call site would bypass all of them silently.
#
# create_checkout_session_test.rb already asserts, at the unit level, that
# THIS service never calls Stripe::PaymentLink -- keep that test, it
# documents the rule where the code lives. It is blind to a regression
# anywhere else, which is exactly what this test scans the whole tree to
# catch.
#
# If you trip this guard: remove the Stripe::PaymentLink reference, or route
# your new Checkout::Session.create call through
# Services::Billing::CreateCheckoutSession instead of calling the Stripe SDK
# directly. Do not add an allowlist entry -- there is deliberately none.
class StripeCheckoutSessionCallSitesTest < ActiveSupport::TestCase
  EXPECTED_SESSION_CREATE_FILE = "app/lib/services/billing/create_checkout_session.rb"

  test "no reference to Stripe::PaymentLink anywhere in app or lib" do
    assert_empty payment_link_offenders,
      "Found a Stripe::PaymentLink reference in: #{payment_link_offenders.join(", ")}.\n" \
      "This app must never create a session through a Payment Link -- see " \
      "docs/specs/membership-and-stripe-billing.md, \"Legacy coexistence\". A Payment Link " \
      "session carries a payment_link id, which defeats the legacy books app's structural " \
      "guard for recognising sessions that are not its own, silently re-opening a defect " \
      "on a system this app cannot see or test against."
  end

  test "exactly one Stripe::Checkout::Session.create call site" do
    assert_equal [EXPECTED_SESSION_CREATE_FILE], session_create_offenders,
      "Expected the only Stripe::Checkout::Session.create call site to be " \
      "#{EXPECTED_SESSION_CREATE_FILE}, found: #{session_create_offenders.join(", ")}.\n" \
      "Every legacy-coexistence metadata tag (origin_app, subscription_data[metadata]) is " \
      "applied inside that one service -- see docs/specs/membership-and-stripe-billing.md, " \
      "\"Legacy coexistence\". A second call site would bypass all of it. Route your new " \
      "call through Services::Billing::CreateCheckoutSession instead of calling the Stripe " \
      "SDK directly."
  end

  private

  def payment_link_offenders
    @payment_link_offenders ||= grep_target_files(/Stripe::PaymentLink/)
  end

  def session_create_offenders
    @session_create_offenders ||= grep_target_files(/Stripe::Checkout::Session\.create/)
  end

  def grep_target_files(pattern)
    target_files.select { |relative_path| File.read(Rails.root.join(relative_path)).match?(pattern) }.sort
  end

  # Only app/ and lib/ -- Stripe calls are backend Ruby code, never views,
  # components, JS, or helpers, so this deliberately does not mirror the
  # daisyUI lint test's broader target set. *.rb AND *.rake: lib/tasks/*.rake
  # is exactly the kind of file where someone reaches for the Stripe SDK
  # directly, and a plain *.rb glob would miss it entirely. Restricting to
  # these extensions also keeps this test itself, under test/lint/,
  # structurally out of scope: it lives outside both globbed trees.
  def target_files
    Dir.glob(Rails.root.join("{app,lib}/**/*.{rb,rake}"))
      .select { |path| File.file?(path) }
      .map { |path| Pathname.new(path).relative_path_from(Rails.root).to_s }
      .sort
  end
end
