# frozen_string_literal: true

# Prefers the IP Cloudflare recorded for the visitor over the shared edge IP
# every other visitor at that PoP appears to have. This is correct ONLY for
# traffic that actually came through Cloudflare: nginx has no real_ip module
# configured with Cloudflare's ranges (a deployment change, not a code one --
# see the ops runbook), so nothing here verifies the request came through
# Cloudflare at all. A request straight to the origin can set this header to
# anything and evade the rate limit entirely -- it does not merely fall back
# to request.remote_ip, which alone was at least accurate for that traffic.
#
# request.remote_ip is only the fallback, for requests that did not come
# through Cloudflare at all -- local development, and health checks hitting
# the origin directly.
#
# Every IP-keyed rate limit in this app must go through here.
module VisitorIp
  extend ActiveSupport::Concern

  private

  def visitor_ip
    request.headers["CF-Connecting-IP"].presence || request.remote_ip
  end
end
