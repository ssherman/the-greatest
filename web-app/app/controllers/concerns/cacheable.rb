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
    expires_in 6.hours, public: true, stale_while_revalidate: 1.hour
  end

  # 24 hours with 1 hour stale-while-revalidate (for show/detail pages)
  def cache_for_show_page
    expires_in 24.hours, public: true, stale_while_revalidate: 1.hour
  end

  # Explicitly prevent caching (for admin, auth, search)
  def prevent_caching
    response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate, private"
    response.headers["Pragma"] = "no-cache"
  end
end
