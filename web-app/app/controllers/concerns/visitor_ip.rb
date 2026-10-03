# frozen_string_literal: true

# The visitor's IP, for keying rate limits and recording who submitted what.
#
# It is request.remote_ip, which is the visitor only because of how the origin
# is wired (deployment/README.md, origin lockdown):
#   - nginx accepts connections only from Cloudflare's ranges, and its real_ip
#     module takes CF-Connecting-IP only from those ranges, so nginx's
#     $remote_addr is the visitor.
#   - nginx appends $remote_addr to X-Forwarded-For. Rails' RemoteIp walks that
#     header from the right, skipping trusted proxies (nginx's container has a
#     private Docker bridge address, which Rails trusts by default), so the
#     first untrusted entry is the visitor. Entries a client added further left
#     are never reached.
#   - The web container publishes no port, so nothing reaches Rails without
#     going through nginx. A request that did would be believed on its own
#     X-Forwarded-For.
#
# Never read CF-Connecting-IP here: Rails cannot tell whether Cloudflare or the
# client set it. nginx can, and has already folded it into $remote_addr.
#
# Every IP-keyed rate limit in this app goes through here.
module VisitorIp
  extend ActiveSupport::Concern

  private

  def visitor_ip
    request.remote_ip
  end
end
