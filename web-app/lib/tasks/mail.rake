namespace :mail do
  desc "Send a smoke-test email to ADMIN_NOTIFICATION_EMAIL to verify delivery works"
  task :smoke, [:domain] => :environment do |_task, args|
    recipient = ENV["ADMIN_NOTIFICATION_EMAIL"]
    abort "ADMIN_NOTIFICATION_EMAIL is not set" if recipient.blank?
    abort "MAIL_FROM_ADDRESS is not set" if ENV["MAIL_FROM_ADDRESS"].blank?
    abort "SENDGRID_API_KEY is not set" if Rails.env.production? && ENV["SENDGRID_API_KEY"].blank?

    domain = args[:domain].presence || "books"

    # deliver_now, not deliver_later: the point is to see the failure here, in
    # this terminal, rather than in a Sidekiq retry nobody is watching.
    SystemMailer.smoke_test(domain: domain, to: recipient).deliver_now

    # MailBranding.for falls back silently for an unrecognized domain, so print
    # what was actually resolved and sent, not the raw argument the operator typed.
    resolved_domain = MailBranding.for(domain).key
    puts "Sent a #{resolved_domain} smoke test to #{recipient} via #{ActionMailer::Base.delivery_method}."
  end
end
