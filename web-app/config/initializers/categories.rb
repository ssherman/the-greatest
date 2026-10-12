# frozen_string_literal: true

# Books subject/location settings. Rails config, not an admin UI.
# Spec: docs/superpowers/specs/2026-10-11-books-category-cleanup-design.md
Rails.application.configure do
  # Subject and location categories are not listed on browse pages when they
  # have fewer ranked books than this, nor in the public filter search when
  # their catalog item_count (all links, ranked or not) is below it (spec §6).
  # Their pages still render; genres are exempt.
  config.x.books.browse_min_category_books = 5

  # Cleanup pipeline (spec §4).
  # Categories with at least this many direct links are the "head": they go to
  # the AI one per call and form the known vocabulary in every prompt.
  config.x.categories_cleanup.head_min_links = 20
  # Tail batch size. Stays 1 until categories:cleanup:calibrate shows a larger
  # size agrees with one-at-a-time answers at least 97% of the time.
  config.x.categories_cleanup.tail_batch_size = 1
  # Books with more direct locations than this get the trim pass (spec §5).
  config.x.categories_cleanup.max_direct_locations = 15
  # Sample books shown to the model per category.
  config.x.categories_cleanup.sample_titles = 5
  # Rough cost of one standard-role flex call with a cached system prompt, in
  # USD (2026-09 research prices; re-check before a production run), and the
  # estimate above which a propose stage needs FORCE=1.
  config.x.categories_cleanup.estimated_cost_per_call = 0.004
  config.x.categories_cleanup.max_unforced_cost = 50
end
