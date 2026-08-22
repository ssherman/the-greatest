# Customer-facing membership mail.
#
# Every action takes the Membership and reads its origin_domain -- never
# Current.domain, which is nil in Sidekiq where these are delivered.
class MembershipMailer < ApplicationMailer
  def welcome(membership)
    @membership = membership
    @renews_on = membership.current_period_end

    branded_mail(
      domain: membership.origin_domain,
      to: membership.user.email,
      subject: "Welcome to #{MailBranding.for(membership.origin_domain).site_name}"
    )
  end

  # The member cancelled, but still holds another access-granting membership,
  # so nothing about their access changes.
  def canceled_with_other_active(membership)
    @membership = membership
    @access_until = membership.current_period_end

    branded_mail(
      domain: membership.origin_domain,
      to: membership.user.email,
      subject: "Your #{MailBranding.for(membership.origin_domain).site_name} membership was cancelled"
    )
  end

  # The member cancelled their last one. Access ends at the end of the period
  # they already paid for -- Membership.granting_access keeps a cancelled
  # Stripe membership granting access until current_period_end.
  def canceled_last(membership)
    @membership = membership
    @access_until = membership.current_period_end

    branded_mail(
      domain: membership.origin_domain,
      to: membership.user.email,
      subject: "Your #{MailBranding.for(membership.origin_domain).site_name} membership has ended"
    )
  end

  # Anonymous donations are supported and create no Customer, so the recipient
  # is the address Stripe collected at checkout, not a user record.
  def donation_receipt(donation)
    @donation = donation
    @amount = ActiveSupport::NumberHelper.number_to_currency(donation.amount_in_dollars)

    branded_mail(
      domain: donation.domain,
      to: donation.email,
      subject: "Thank you for your donation to #{MailBranding.for(donation.domain).site_name}"
    )
  end
end
