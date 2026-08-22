# Preview all emails at http://localhost:3000/rails/mailers
class AdminMailerPreview < ActionMailer::Preview
  def new_subscription = AdminMailer.new_subscription(sample_membership("music"))

  # Not hypothetical -- every membership created before checkout existed
  # (including the entire account-wide migration) has origin_domain: nil, and
  # MailBranding.for(nil) falls back to books.
  def new_subscription_unknown_domain = AdminMailer.new_subscription(sample_membership(nil))

  def subscription_canceled = AdminMailer.subscription_canceled(sample_membership("books"))

  def subscription_canceled_unknown_domain
    AdminMailer.subscription_canceled(sample_membership(nil))
  end

  def new_donation = AdminMailer.new_donation(sample_donation("games", user: User.new(id: 0)))

  def new_donation_unknown_domain
    AdminMailer.new_donation(sample_donation(nil, user: User.new(id: 0)))
  end

  def anonymous_donation = AdminMailer.anonymous_donation(sample_donation("books", user: nil))

  def anonymous_donation_unknown_domain
    AdminMailer.anonymous_donation(sample_donation(nil, user: nil))
  end

  private

  # Built in memory, never saved -- a preview must not write to the database.
  def sample_membership(domain)
    Membership.new(
      id: 0,
      user: User.new(email: "member@example.org"),
      source: :stripe,
      status: :active,
      interval: :monthly,
      origin_domain: domain,
      current_period_end: 1.month.from_now
    )
  end

  def sample_donation(domain, user:)
    Donation.new(id: 0, amount_cents: 5000, currency: "usd", email: "donor@example.org",
      domain: domain, user: user)
  end
end
