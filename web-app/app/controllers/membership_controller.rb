# frozen_string_literal: true

# The join / support page. Global route, per-domain layout, never edge-cached:
# it renders differently for members and non-members.
#
# Task 11 adds checkout, donate, portal and thanks. This is the shell the
# members' area redirects to.
class MembershipController < ApplicationController
  include Cacheable
  include DomainLayout

  layout :resolve_layout

  before_action :prevent_caching

  def show
    @membership = current_user&.granting_membership
  end
end
