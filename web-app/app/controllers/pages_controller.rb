# frozen_string_literal: true

# Flat, content-only pages: the privacy and deletion policies.
#
# Global routes with a per-domain layout, the same shape as MembershipController
# and MyListsController -- one company, one policy, served on every site with
# the layout resolved from Current.domain at request time.
#
# Edge-cached for a day. These change a few times a decade, they render the same
# bytes for every visitor, and they are linked from the footer of every page on
# three sites, so they are the last thing that should reach Rails.
class PagesController < ApplicationController
  include Cacheable
  include DomainLayout

  layout :resolve_layout

  before_action :cache_for_show_page
  before_action :mark_indexable

  # The date the text below was last substantively changed. Displayed on the
  # privacy page. A constant rather than a file mtime so that reformatting the
  # ERB does not silently claim the policy itself changed.
  LAST_UPDATED = Date.new(2026, 8, 26)

  def privacy
  end

  def deletion
  end

  private

  # The three sites' robots helpers have OPPOSITE defaults: music and games are
  # opt-out (`@indexable == false ? noindex : index`), books is opt-in
  # (`@indexable ? index : noindex`). Setting nothing therefore indexes these
  # pages on two sites and hides them on the third -- and because books is also
  # gated behind BOOKS_PUBLIC_INDEXING, that only shows up at cutover. These are
  # public, static and canonical, so index them everywhere, deliberately.
  def mark_indexable
    @indexable = true
  end
end
