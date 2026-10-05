# frozen_string_literal: true

# Goodreads page fetching (Goodreads import spec §6, "Politeness"). Rails
# config, not an admin UI. Measured 2026-10-04 on 22 fetches: 4-8 s each,
# 25-180 KB gzipped.
Rails.application.config.x.goodreads = ActiveSupport::OrderedOptions.new.merge(
  # Seconds from one fetch start to the next: at most 240 an hour.
  fetch_interval: 15,
  # Fetches reserved per UTC day.
  daily_fetch_cap: 1_500,
  # How long a 403, a challenge page or a page the parser cannot recognize
  # stops every fetch.
  block_cooldown: 6.hours.to_i,
  # Tries for a fetch that got no answer (Goodreads' 503 page, a timeout)
  # before the edition is created unverified for the sweep.
  fetch_attempts: 3,
  # Matches a book page, the not-found page and Goodreads' error page alike,
  # so no fetch waits out its timeout (the book-title selector cost 43 s on
  # the other two).
  wait_for_selector: "h1",
  fetch_timeout_ms: 30_000
)
