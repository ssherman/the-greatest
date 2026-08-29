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
  helper_method :correction_url

  # Goes to the PUBLIC contact address, not admin_address. That variable is for
  # sales and donation alerts; the footer already advertises this address, so
  # the form and the mailto land in the same inbox.
  def contact_message(contact_message)
    @contact_message = contact_message
    @site_name = MailBranding.for(contact_message.domain).site_name

    branded_mail(
      domain: contact_message.domain,
      to: SiteContact::ADDRESS,
      subject: "Contact via #{@site_name}: #{contact_message.message.truncate(60)}",
      reply_to: contact_message.email
    )
  end

  private

  def admin_address
    address = ENV["ADMIN_NOTIFICATION_EMAIL"]
    raise MissingAdminAddress, "ADMIN_NOTIFICATION_EMAIL is not set" if address.blank?

    address
  end

  # Called from the view, not eagerly in new_correction above: branded_mail sets
  # default_url_options from the resolved domain, and only does so immediately
  # before it calls `mail`, which is what triggers template rendering. A _url
  # helper called any earlier raises "Missing host to link to!" in dev/test
  # (there is no class-level default there) and silently links to the BOOKS host
  # in production (config/environments/production.rb sets one, for books only)
  # -- the exact wrong-domain-branding bug this mailer exists to avoid.
  #
  # Reuses Admin::CorrectionsController::ADMIN_PATHS -- the single source of
  # truth for which route helper prefix each domain's admin namespace uses --
  # rather than keeping a second copy here that could drift from it. _url, not
  # _path: this mailer runs inside Sidekiq, with no request to make a relative
  # path absolute against.
  def correction_url
    domain = Services::Corrections::TypeRegistry.domain_for(@correction.correctable_type)
    helper_name = Admin::CorrectionsController::ADMIN_PATHS.fetch(domain).to_s
      .delete_suffix("s_path") + "_url"
    public_send(helper_name, @correction)
  end
end
