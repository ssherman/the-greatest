# frozen_string_literal: true

# Tunables for the public API. Rails config, not an admin UI: changing a limit
# is a reviewed deploy, and there is exactly one place to read to know the
# whole answer. Spec: docs/superpowers/specs/2026-09-12-public-api-framework-design.md §4.
#
# Limits are keyed on the ACCOUNT, never the token, so minting more tokens
# never multiplies quota. The system tier is finite on purpose: it protects
# Postgres from a runaway agent loop, not from us.
Rails.application.configure do
  config.x.api.rate_limits = {
    member: {per_minute: 60, per_day: 5_000},
    system: {per_minute: 600, per_day: 200_000},
    admin: {per_minute: 600, per_day: 200_000}
  }

  # 401 responses per visitor IP per minute. Bounds database load from junk;
  # the defence against guessing is the token's 238 bits of entropy, not this.
  config.x.api.unauthenticated_per_minute = 60

  config.x.api.max_tokens_per_user = 10

  # OAuth endpoints, per visitor IP per minute. Dynamic client registration is
  # rare (a client registers once), so its limit is the tightest.
  # Spec: docs/superpowers/specs/2026-11-02-mcp-oauth-design.md D13.
  config.x.api.oauth_register_per_minute = 10
  config.x.api.oauth_token_per_minute = 30

  # How long an admin connection may keep refreshing after the admin approved
  # it. Past this the refresh is invalid_grant (the connection is not revoked)
  # and the admin approves again. Member connections have no such limit.
  # Spec: docs/superpowers/specs/2026-11-02-mcp-oauth-design.md D5.
  config.x.api.oauth_admin_approval_lifetime = 30.days

  # A dynamically registered client that nobody approved within this long is
  # deleted by Oauth::PruneJob (spec D6: "no grant after 30 days").
  config.x.api.oauth_unused_client_lifetime = 30.days

  # How long a used or expired authorization code row is kept. Doorkeeper codes
  # live 10 minutes, so a day is far more than any check needs.
  config.x.api.oauth_grant_retention = 1.day

  # Egress ranges of hosted MCP connectors. Thousands of users reach us from
  # these few addresses, so a per-IP limit would throttle one user's neighbours.
  # An address inside a range shares one counter named for the range, with the
  # budget in connector_range_per_minute below, instead of a per-IP window.
  # Published by the vendor, not secrets. Sources:
  #   https://claude.com/docs/connectors/building/authentication.md (connector egress, 160.79.104.0/21)
  #   https://platform.claude.com/docs/en/api/ip-addresses (153.61.208.0/20)
  # Adding another vendor is one entry here.
  config.x.api.connector_egress_ranges = {
    anthropic: %w[160.79.104.0/21 153.61.208.0/20]
  }

  # Per-minute budget for each range above, keyed by window (the pre-auth 401
  # window, dynamic client registration, the token endpoint).
  config.x.api.connector_range_per_minute = {
    unauthenticated: 3_000,
    oauth_register: 600,
    oauth_token: 3_000
  }
end
