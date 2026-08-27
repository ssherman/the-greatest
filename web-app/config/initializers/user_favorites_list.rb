# frozen_string_literal: true

# Tuning knobs for Services::Lists::UserFavoritesTally and the list it generates.
#
# These are defaults. Every key is overridable per call by keyword, which is how
# tests pin behaviour without mutating global state. Changing production
# behaviour means editing this file and deploying -- deliberate, because tuning
# is a development activity done against real data.
#
# decay_exponent only affects CURATED ballots. It barely moves the outcome
# (measured on real books data, 1.0 and 3.0 produce 245 of the same 250 books);
# what it changes is what curating does to a user's own ballot. At 2.0 a user's
# top pick carries roughly 3x a flat vote while their lower favorites still
# count. At 3.0 everything past ~#35 of a 51-book list rounds to zero.
#
# min_voters is inert for books today -- 2,651 books clear it and only 250 are
# taken -- but it stops one person's obscure pick reaching a public page in the
# domains that have almost no data yet.
Rails.application.config.x.user_favorites_list = ActiveSupport::OrderedOptions.new.merge(
  max_items: 250,
  min_voters: 2,
  decay_exponent: 2.0
)
