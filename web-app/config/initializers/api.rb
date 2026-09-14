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
    system: {per_minute: 600, per_day: 200_000}
  }

  # 401 responses per visitor IP per minute. Bounds database load from junk;
  # the defence against guessing is the token's 238 bits of entropy, not this.
  config.x.api.unauthenticated_per_minute = 60

  config.x.api.max_tokens_per_user = 10
end
