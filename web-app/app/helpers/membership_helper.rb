# frozen_string_literal: true

module MembershipHelper
  # "Is this feature behind the paywall?" -- for rendering a members-only marker
  # next to something. It answers a question about the FEATURE, not about the
  # viewer; pair it with current_user&.member? when deciding what to show.
  def members_only?(feature) = MembershipGate.members_only?(feature)

  # Membership status in words. Never colour alone, and never green-versus-red:
  # a red-green colour-blind reader must get the same information from the text.
  #
  # Every branch that names a stored current_period_end checks whether that date
  # is already in the past. Every call site today passes User#granting_membership,
  # which excludes expired rows, so most past-dated branches are unreachable
  # through the app right now -- but this helper does not get to assume that
  # stays true, and a stale date must never be described as still in effect
  # ("runs until", "stays active until") once it has already passed.
  #
  # The one exception is the active/trialing Stripe branch just below:
  # Membership.granting_access deliberately grants access to those rows without
  # checking current_period_end at all, because our stored copy of the date can
  # be stale relative to Stripe. So an active member CAN reach this helper with
  # a past date, and the past case there must not claim they have lost access
  # (they have not) -- only that the date on file is not to be trusted.
  def membership_status_sentence(membership)
    return "You are not currently a member." if membership.nil?

    ends_on = membership.current_period_end
    ended = ends_on&.past?

    if membership.source_stripe? && membership.cancel_at_period_end? && ends_on
      if ended
        "Your membership was cancelled and ended on #{ends_on.to_fs(:long)}."
      else
        "Your membership is cancelled and stays active until #{ends_on.to_fs(:long)}."
      end
    elsif membership.source_stripe? && membership.canceled? && ends_on
      if ended
        "Your membership has ended; access ended on #{ends_on.to_fs(:long)}."
      else
        "Your membership has ended and access runs until #{ends_on.to_fs(:long)}."
      end
    elsif membership.source_stripe? && ends_on
      if ended
        "Your #{membership.interval} membership is active; we don't have an up-to-date renewal date for it."
      else
        "Your #{membership.interval} membership renews on #{ends_on.to_fs(:long)}."
      end
    elsif ends_on
      if ended
        "Your membership ended on #{ends_on.to_fs(:long)}."
      else
        "Your membership runs until #{ends_on.to_fs(:long)}."
      end
    else
      "Your membership does not expire."
    end
  end
end
