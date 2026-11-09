# frozen_string_literal: true

# Pacing and etiquette for every call to a Wikimedia host. Wikidata is answered by the
# local service (docs/features/wikidata-data-service.md), so this pacing is for
# Wikipedia only. Spec: docs/superpowers/specs/2026-09-27-books-author-importer-design.md §4.
#
# Measured 2026-09-27: the 2026 limits apply to every per-wiki api.php, at
# 200 requests a minute for a client whose User-Agent follows the policy. No host
# sends rate-limit headers on success, so the only signals are a 429 with
# Retry-After and the Action API's maxlag error. One request a second is under a
# third of the cap.
Rails.application.config.x.wikimedia = ActiveSupport::OrderedOptions.new.merge(
  requests_per_window: 1,
  window_seconds: 1.0,
  max_inline_wait: 5.0,
  # The evidence lane runs one step at a time, so waiting for a slot there blocks
  # nothing else and beats giving up and restarting the gather. Everyone else
  # keeps max_inline_wait. See Services::Books::Evidence::Gather.
  evidence_max_inline_wait: 30.0,
  maxlag: 5,
  contact: ENV.fetch("WIKIMEDIA_CONTACT", "https://thegreatestbooks.org")
)
