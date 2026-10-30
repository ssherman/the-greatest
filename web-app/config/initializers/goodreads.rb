# frozen_string_literal: true

# Reads an integer setting from ENV for the Goodreads initializers (this file
# and goodreads_rebuild.rb, which Rails loads after it). A bad value
# (blank, "1,500", "08x") must never stop the app booting, so it falls back to
# the default and says so in the log. Parsed as base 10, so "010" is ten, not eight.
module GoodreadsEnv
  def self.integer(name, default)
    raw = ENV[name]
    return default if raw.nil?

    Integer(raw.strip, 10)
  rescue ArgumentError
    message = "#{name}=#{raw.inspect} is not a whole number; using #{default}"
    Rails.logger ? Rails.logger.warn(message) : warn(message)
    default
  end
end

# Goodreads page fetching (Goodreads import spec §6, "Politeness"). Rails
# config, not an admin UI. Measured 2026-10-04 on 22 fetches: 4-8 s each,
# 25-180 KB gzipped.
Rails.application.config.x.goodreads = ActiveSupport::OrderedOptions.new.merge(
  # Seconds from one fetch start to the next: at most 240 an hour. Set
  # GOODREADS_FETCH_INTERVAL to change it without a deploy. The interval bounds
  # the cap: 86,400 / interval is the most fetches a day can hold, 5,760 at 15 s,
  # so raising the cap past that needs a shorter interval too.
  fetch_interval: GoodreadsEnv.integer("GOODREADS_FETCH_INTERVAL", 15),
  # Fetches reserved per UTC day. GOODREADS_DAILY_FETCH_CAP overrides it.
  daily_fetch_cap: GoodreadsEnv.integer("GOODREADS_DAILY_FETCH_CAP", 1_500),
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
