# frozen_string_literal: true

# Puts a controller action behind the paywall.
#
#   include MembershipGated
#   before_action -> { require_membership!(:members_area) }
#
# Redirects rather than 403s: a non-member landing on a members-only URL should
# be shown how to become a member, not told off. Both branches land on
# /membership because that is where both the sign-in modal and the plans live.
module MembershipGated
  extend ActiveSupport::Concern

  private

  def require_membership!(feature)
    MembershipGate.validate!(feature)
    return if current_user&.member?

    message = if current_user
      "That page is for members. Membership covers every site."
    else
      "Sign in to your membership to open that page."
    end

    redirect_to membership_path, alert: message
  end
end
