# frozen_string_literal: true

# Provides HTTP caching methods for controllers.
# Used to set Cache-Control headers for Cloudflare edge caching.
#
# Usage:
#   class MyController < ApplicationController
#     include Cacheable
#     before_action :cache_for_index_page, only: [:index]
#     before_action :cache_for_show_page, only: [:show]
#   end
#
module Cacheable
  extend ActiveSupport::Concern

  private

  # 6 hours with 1 hour stale-while-revalidate (for index/list pages)
  def cache_for_index_page
    return prevent_caching if user_owned_ranking_configuration?

    skip_session_for_caching
    expires_in 6.hours, public: true, stale_while_revalidate: 1.hour
  end

  # 24 hours with 1 hour stale-while-revalidate (for show/detail pages)
  def cache_for_show_page
    return prevent_caching if user_owned_ranking_configuration?

    skip_session_for_caching
    expires_in 24.hours, public: true, stale_while_revalidate: 1.hour
  end

  # Explicitly prevent caching (for admin, auth, search)
  def prevent_caching
    response.cache_control.replace(no_store: true, private: true)
    response.headers["Pragma"] = "no-cache"
  end

  # Disable session cookie for cacheable responses.
  # Cloudflare bypasses cache when Set-Cookie header is present.
  def skip_session_for_caching
    request.session_options[:skip] = true
  end

  # A user-owned ranking configuration's pages are personal (and may be
  # private), so they are never edge-cached. Every controller that resolves
  # /rc/:id loads @ranking_configuration before it sets cache headers, which
  # is what makes this one guard cover all of them; the controller tests for
  # each /rc/ page pin that ordering.
  def user_owned_ranking_configuration?
    instance_variable_defined?(:@ranking_configuration) && @ranking_configuration&.user_owned?
  end
end
