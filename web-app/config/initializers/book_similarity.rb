# frozen_string_literal: true

# Tuning knobs for Services::Books::SimilarBooks and its OpenSearch query.
#
# These are defaults. Every key is overridable per call by keyword, which is how
# tests pin behaviour without mutating global state. Changing production
# behaviour means editing this file and deploying -- deliberate, because tuning
# is a development activity done against real data.
#
# Tuned 2026-08-26 against the dev corpus (126,324 books) with
# `bin/rails books:similar:compare`. Every number below was measured, not guessed;
# the measurements are recorded next to each one.
#
# min_score and max_category_item_count are COUPLED and must be retuned together.
# The ceiling decides how many `should` clauses the query carries, and the score is
# their sum divided by sqrt(category count) -- so lowering the ceiling lowers every
# score. Gatsby's window tops out at 8.16 under a 25,000 ceiling and 6.74 under
# 15,000. A min_score carried over from a different ceiling means nothing.
Rails.application.config.x.book_similarity = ActiveSupport::OrderedOptions.new.merge(
  limit: 5,
  page_limit: 25,
  # 2, not 3. Measured over 150 books: over_fetch 2 returns an IDENTICAL card to
  # over_fetch 3 for 150 of 150, and an identical 25-item page for 60 of 60, while
  # halving the service call (60ms -> 28ms mean). This is the only knob whose cost
  # is paid in Postgres -- 3 loaded 75 rows to render 25. The headroom exists for
  # apply_author_cap, and the cap was measured removing 0-3 books from the top ~25,
  # which a 2x window absorbs with room to spare.
  over_fetch: 2,

  # 3.0, was 0 (disabled). Measured across a 150-book sample spanning the whole
  # corpus, not just ranked books: 3.0 trims 7.8% of page slots -- the weak tail of
  # the 25-result grid -- and emptied ZERO cards. 3.5 trims 18.7% but empties 3
  # books; 4.0 trims 28.6% and empties 11. A second 200-book sample put 3.0's
  # empty rate at 2%, so treat ~0-2% as the real figure: those are books whose best
  # match scores below 3.0, which render "No similar books found" rather than 25
  # bad ones. Do not raise this without re-running the sweep -- the card fails
  # quiet, so an over-aggressive value is invisible in production.
  min_score: 3.0,

  # The four accuracy behaviours, each independently switchable.
  require_genre_match: true,

  # Fiction/Nonfiction are a book-level TYPE, not a genre: never scored (in the
  # numerator -- see the KNOWN GAP note in BookSimilar), and used to
  # exclude candidates of the OPPOSITE type (never to require the same one -- see
  # BookSimilar.opposite_type_clause for why that distinction matters). Measured
  # across 192 fiction/nonfiction source books before this existed: 5.2% of #1
  # results and 7.6% of top-5 slots were the opposite type. Catch-22 returned The
  # Braindead Megaphone, an essay collection, on shared Dark Humor / Absurdist /
  # Satire / Postmodern -- tone genres that describe manner, not the reading
  # experience.
  exclude_opposite_book_type: true,
  normalize_by_category_count: true,
  drop_common_categories: true,
  exclude_same_series: true,

  max_categories_per_type: 8,

  # 15,000, was 25,000. The highest-leverage knob by a distance, because selecting
  # which categories enter the query is the ONLY mechanism in this design that acts
  # on category rarity -- a term query on a keyword field scores a flat
  # ConstantScore equal to its boost, with no IDF anywhere (measured; see the note
  # in Search::Books::Search::BookSimilar).
  #
  # 15,000 is not a round number picked for feel. Exactly 9 of the corpus's 52,772
  # scoring categories sit above it, and they are precisely the umbrella buckets
  # that say nothing about a book: Fiction (68,333), Nonfiction (56,222), Fictional
  # Location (36,656), Identity (31,658), United States (29,274), Family (21,179),
  # Literary Fiction (17,839), Speculative Fiction (17,090), Family & Relationships
  # (15,288). The next category down is Friendship (14,804), then History (13,874),
  # Political (13,810), Historical fiction (12,318), Mystery (11,971) -- all
  # genuinely informative, all retained. The threshold sits in a real gap.
  #
  # Do not lower it further without re-running the controls. 5,000 was tried and is
  # actively harmful: it drops Science fiction (5,114), at which point Dune returns
  # How The Grinch Stole Christmas.
  max_category_item_count: 15_000,

  # Unchanged at 2, and deliberately a cap rather than an exclusion. Measured
  # removing 0-3 books from the top ~25 -- it is doing its job without crowding
  # anything out.
  max_per_author: 2,

  genre_boost: 5.0,
  subject_boost: 3.0,
  location_boost: 1.0,
  language_boost: 0.5,
  era_boost: 0.3,
  era_years: 50,
  author_boost: 0.1
)
