# frozen_string_literal: true

# The Goodreads re-import (docs/superpowers/specs/2026-11-02-goodreads-reimport-design.md).
# Rails config, not an admin UI; the ENV names let it change without a deploy.
Rails.application.config.x.goodreads_reimport = ActiveSupport::OrderedOptions.new.merge(
  # Off: the match, decide, apply and author-check jobs return without writing.
  enabled: GoodreadsEnv.boolean("GOODREADS_REIMPORT_ENABLED", false),
  # Separately gates enrichment of the books the run creates.
  enrichment: GoodreadsEnv.boolean("GOODREADS_REIMPORT_ENRICHMENT", false)
)
