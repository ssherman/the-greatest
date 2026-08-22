# Answers one question: may this app email about this membership or donation?
#
# The legacy books app is still live on the same Stripe account and still
# emails its own subscribers. Every webhook endpoint receives every event on
# the account, so without this gate a legacy subscriber would get two welcome
# emails for one subscription -- one from each app.
#
# Deliberately top-level, not nested: a constant looked up from inside a nested
# module resolves against that module first, which has produced confusing
# NameErrors in this codebase more than once.
class MembershipEmailScope
  ENV_VAR = "MEMBERSHIP_EMAIL_SCOPE"

  OWN_ONLY = "own_only"
  ALL = "all"

  # @param record [#sold_by_this_app?] a Membership or Donation
  def self.may_email?(record)
    return true if scope == ALL

    record.sold_by_this_app?
  end

  # Anything unrecognised is treated as own_only. A typo in production must not
  # silently start double-emailing every legacy subscriber -- the failure
  # direction matters more than the convenience.
  def self.scope
    (ENV[ENV_VAR] == ALL) ? ALL : OWN_ONLY
  end
end
