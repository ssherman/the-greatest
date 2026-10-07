# frozen_string_literal: true

# Tuning knobs for the recommendation engine (spec §9.3). Defaults only: every
# key is overridable per call through Recommendations::Config.resolve(overrides),
# which is how the harness sweeps values in one process and how tests pin
# behaviour without touching global state. Change production behaviour by
# editing this file and deploying.
Rails.application.config.x.recommendations = ActiveSupport::OrderedOptions.new.merge(
  free_limit: 10,
  member_limit: 50,
  candidate_size: 300,

  # Interaction weights (spec §6.1)
  favorite_weight: 2.0,
  top_favorite_bonus: 0.5,
  top_favorite_count: 10,
  read_weight: 0.4,
  want_to_read_weight: 0.2,
  rating_slope: 0.75,

  # Profile (spec §6.2-6.4)
  lift: true,
  pseudo_books: 10,
  min_support: 2,
  min_support_history: 5,
  negative_gamma: 0.5,
  demote_threshold: 1.0,
  negative_boost: 0.3,
  max_genres: 8,
  max_subjects: 25,
  max_locations: 5,
  genre_multiplier: 1.0,
  subject_multiplier: 0.8,
  location_multiplier: 0.4,
  fiction_share_high: 0.9,
  fiction_share_low: 0.1,

  # Query (spec §7)
  normalization_floor: 10,
  min_score: 1.0,

  # Fusion (spec §5.4)
  rrf_k: 60,
  taste_weight: 1.0,
  collaborative_half_point: 10,
  rank_prior_weight: 0.3,

  # Re-ranking and explanations (spec §8)
  max_per_author: 2,
  calibrate_genres: true,
  calibration_lambda: 0.3,
  calibration_alpha: 0.01,
  explain_threshold: 1.0
)
