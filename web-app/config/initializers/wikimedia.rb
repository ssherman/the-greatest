# frozen_string_literal: true

# Pacing and etiquette for every call to a Wikimedia host: the Wikidata
# Action API, the Wikidata Query Service and Wikipedia. Spec:
# docs/superpowers/specs/2026-09-27-books-author-importer-design.md §4.
#
# Measured 2026-09-27: the 2026 limits apply to every per-wiki api.php, at
# 200 requests a minute for a client whose User-Agent follows the policy;
# the Query Service keeps its own budget (60 s of query time a minute, 5
# parallel queries). No host sends rate-limit headers on success, so the
# only signals are a 429 with Retry-After and the Action API's maxlag error.
# One request a second across all three hosts is under a third of the cap.
Rails.application.config.x.wikimedia = ActiveSupport::OrderedOptions.new.merge(
  requests_per_window: 1,
  window_seconds: 1.0,
  max_inline_wait: 5.0,
  maxlag: 5,
  contact: ENV.fetch("WIKIMEDIA_CONTACT", "https://thegreatestbooks.org")
)
