# Preview all emails at http://localhost:3000/rails/mailers
class MembershipMailerPreview < ActionMailer::Preview
  def welcome_books = MembershipMailer.welcome(sample_membership("books"))

  def welcome_music = MembershipMailer.welcome(sample_membership("music"))

  # Not hypothetical -- every membership created before checkout existed
  # (including the entire account-wide migration) has origin_domain: nil, and
  # MailBranding.for(nil) falls back to books. This is what proves that
  # fallback renders, not just resolves.
  def welcome_unknown_domain = MembershipMailer.welcome(sample_membership(nil))

  def canceled_last = MembershipMailer.canceled_last(sample_membership("books"))

  def canceled_last_unknown_domain = MembershipMailer.canceled_last(sample_membership(nil))

  def canceled_with_other_active
    MembershipMailer.canceled_with_other_active(sample_membership("games"))
  end

  def canceled_with_other_active_unknown_domain
    MembershipMailer.canceled_with_other_active(sample_membership(nil))
  end

  def donation_receipt = MembershipMailer.donation_receipt(sample_donation("books"))

  def donation_receipt_unknown_domain = MembershipMailer.donation_receipt(sample_donation(nil))

  private

  # Built in memory, never saved -- a preview must not write to the database.
  def sample_membership(domain)
    Membership.new(
      id: 0,
      user: User.new(email: "member@example.org"),
      source: :stripe,
      status: :active,
      interval: :yearly,
      origin_domain: domain,
      current_period_end: 1.year.from_now
    )
  end

  def sample_donation(domain)
    Donation.new(id: 0, amount_cents: 2500, currency: "usd", email: "donor@example.org", domain: domain)
  end
end
