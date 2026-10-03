# frozen_string_literal: true

# Rack prefers an RFC 7239 Forwarded header over X-Forwarded-For when both are
# present, and Rails' RemoteIp follows it. nginx never sends Forwarded -- it
# appends the real_ip visitor to X-Forwarded-For (see the VisitorIp concern) --
# so a Forwarded header can only have come from the client, and believing it
# would let anyone pick their own remote_ip and dodge every IP-keyed rate limit.
Rack::Request.forwarded_priority = [:x_forwarded]
