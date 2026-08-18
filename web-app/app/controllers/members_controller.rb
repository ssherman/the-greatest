# frozen_string_literal: true

# The members' area -- the first surface behind the paywall.
#
# Global route, no DomainConstraint: one membership covers every site, so this
# page is served on every host with the layout resolved from Current.domain.
# Never cached: it is per-user by definition.
class MembersController < ApplicationController
  include Cacheable
  include DomainLayout
  include MembershipGated

  layout :resolve_layout

  before_action :prevent_caching
  before_action -> { require_membership!(:members_area) }

  def show
    @membership = current_user.granting_membership
  end
end
