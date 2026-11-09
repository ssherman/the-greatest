# frozen_string_literal: true

# Re-checking after a refresh of the local Wikidata copy (see
# Wikidata::RecheckAfterRefreshJob). Off everywhere: the owner starts bulk
# enrichment by hand, and turns this on after launch (docs/launch-todo.md §15).
Rails.application.config.x.wikidata = ActiveSupport::OrderedOptions.new.merge(
  recheck_after_refresh: false,
  # How far back a book or author counts as recent enough to re-check.
  recheck_window: 90.days
)
