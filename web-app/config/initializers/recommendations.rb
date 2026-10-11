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
  lift_cap: 0,                 # max lift weight per category; 0 = uncapped
  lift_population: "catalog",  # "catalog" (all non-provisional books) or "ranked" (the ranked pool) for p_c
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
  # Quality prior inside the score: taste × (floor + (1 − floor) · scale / (scale + ranked_position)).
  # scale 0 = off, the default since 2026-10-10: on, it turned a 312-positive reader's page into
  # the all-time top 100 minus their shelf (docs/data-quality/recommendations-canon-2026-10-10.md);
  # the harness had scored it a win because held-out favorites are mostly famous books.
  # min_score applies to the taste score BEFORE this multiplier (the query's script enforces it),
  # so the prior re-orders the pool and never empties it.
  quality_scale: 0,
  quality_floor: 0.3,
  # The user-facing "depth" setting (spec §9.4 "deep cuts") as engine overrides: Safer bets turns
  # the quality prior on, Deep cuts also drops the fusion rank prior, Balanced stores nothing.
  depth_overrides: {"safe" => {quality_scale: 1000, quality_floor: 0.3}.freeze, "deep" => {rank_prior_weight: 0}.freeze}.freeze,

  # Fusion (spec §5.4) and the collaborative signal (spec 2 §6, §7)
  rrf_k: 60,
  taste_weight: 1.0,
  collaborative: true,            # false = the signal reports itself unavailable (the harness's taste-only variant)
  collaborative_half_point: 10,
  # The list's fusion weight at a full shelf, against taste's 1.0: collaborative_weight × n / (n +
  # collaborative_half_point). At 1.0 the model's neighbours of famous books (more famous books)
  # took most of the page for a large shelf (same record as above); at 0.25, about two picks in twenty.
  collaborative_weight: 0.25,
  collaborative_min_rating: 3,    # a rating at or above this is a positive, for training and for the shelf scored at serving time
  collaborative_overfetch: 2,     # neighbour rows fetched = overfetch × candidate_size, so the ranked-pool filter can drop some and still fill
  because_of_rating: 4,           # "Because you loved X" only names a favorite or a book rated at least this
  rank_prior_weight: 0.3,

  # Re-ranking and explanations (spec §8)
  max_per_author: 2,
  calibrate_genres: true,
  calibration_lambda: 0.3,
  calibration_alpha: 0.01,
  explain_threshold: 1.0
)
