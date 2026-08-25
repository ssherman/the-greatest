# Operational notifications to the site owner. Never customer-facing.
#
# Branded for the site the sale came from, so the owner can tell at a glance
# which property produced it.
class AdminMailer < ApplicationMailer
  class MissingAdminAddress < StandardError; end

  def new_subscription(membership)
    @membership = membership
    @site_name = MailBranding.for(membership.origin_domain).site_name

    branded_mail(
      domain: membership.origin_domain,
      to: admin_address,
      subject: "New membership on #{@site_name}"
    )
  end

  def subscription_canceled(membership)
    @membership = membership
    @site_name = MailBranding.for(membership.origin_domain).site_name

    branded_mail(
      domain: membership.origin_domain,
      to: admin_address,
      subject: "Membership cancelled on #{@site_name}"
    )
  end

  def new_donation(donation)
    @donation = donation
    @amount = ActiveSupport::NumberHelper.number_to_currency(donation.amount_in_dollars)

    branded_mail(
      domain: donation.domain,
      to: admin_address,
      subject: "New donation: #{@amount}"
    )
  end

  def anonymous_donation(donation)
    @donation = donation
    @amount = ActiveSupport::NumberHelper.number_to_currency(donation.amount_in_dollars)

    branded_mail(
      domain: donation.domain,
      to: admin_address,
      subject: "New anonymous donation: #{@amount}"
    )
  end

  def new_correction(correction)
    @correction = correction
    @record = correction.correctable
    @fields = correction.correction_fields.order(:field_name)
    domain = Services::Corrections::TypeRegistry.domain_for(correction.correctable_type)
    @site_name = MailBranding.for(domain).site_name

    branded_mail(
      domain: domain,
      to: admin_address,
      subject: "New correction on #{@site_name}",
      # Only when a real account submitted it. An anonymous correction has no
      # address, and an unverified one would not be a reply channel anyway.
      reply_to: correction.user&.email
    )
  end

  private

  def admin_address
    address = ENV["ADMIN_NOTIFICATION_EMAIL"]
    raise MissingAdminAddress, "ADMIN_NOTIFICATION_EMAIL is not set" if address.blank?

    address
  end
end
