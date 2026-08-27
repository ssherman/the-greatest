# frozen_string_literal: true

# Tuning knobs for Services::Books::SimilarBooks and its OpenSearch query.
#
# These are defaults. Every key is overridable per call by keyword, which is how
# tests pin behaviour without mutating global state. Changing production
# behaviour means editing this file and deploying -- deliberate, because tuning
# is a development activity done against real data.
#
# min_score is 0 (disabled) on purpose. The legacy site used 5, but that was
# tuned against an unnormalised score scale; normalize_by_category_count divides
# every score by sqrt(tag count), so the whole scale shifts and the old number
# means nothing here.
Rails.application.config.x.book_similarity = ActiveSupport::OrderedOptions.new.merge(
  limit: 5,
  page_limit: 25,
  over_fetch: 3,
  min_score: 0,

  # The four accuracy behaviours, each independently switchable.
  require_genre_match: true,
  normalize_by_category_count: true,
  drop_common_categories: true,
  exclude_same_series: true,

  max_categories_per_type: 8,
  max_category_item_count: 25_000,
  max_per_author: 2,

  genre_boost: 5.0,
  subject_boost: 3.0,
  location_boost: 1.0,
  language_boost: 0.5,
  era_boost: 0.3,
  era_years: 50,
  author_boost: 0.1
)
