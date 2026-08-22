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
end
