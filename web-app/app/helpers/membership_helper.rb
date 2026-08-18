# frozen_string_literal: true

module MembershipHelper
  # "Is this feature behind the paywall?" -- for rendering a members-only marker
  # next to something. It answers a question about the FEATURE, not about the
  # viewer; pair it with current_user&.member? when deciding what to show.
  def members_only?(feature) = MembershipGate.members_only?(feature)

  # Membership status in words. Never colour alone, and never green-versus-red:
  # a red-green colour-blind reader must get the same information from the text.
  def membership_status_sentence(membership)
    return "You are not currently a member." if membership.nil?

    ends_on = membership.current_period_end

    if membership.source_stripe? && membership.cancel_at_period_end? && ends_on
      "Your membership is cancelled and stays active until #{ends_on.to_fs(:long)}."
    elsif membership.source_stripe? && membership.canceled? && ends_on
      "Your membership has ended and access runs until #{ends_on.to_fs(:long)}."
    elsif membership.source_stripe? && ends_on
      "Your #{membership.interval} membership renews on #{ends_on.to_fs(:long)}."
    elsif ends_on
      "Your membership runs until #{ends_on.to_fs(:long)}."
    else
      "Your membership does not expire."
    end
  end
end
