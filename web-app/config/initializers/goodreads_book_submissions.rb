# frozen_string_literal: true

# User-added books (a reader asks for a book the site does not have). Rails
# config, not an admin UI. This file is named goodreads_book_submissions.rb
# because GoodreadsEnv is defined in goodreads.rb and initializers load in
# alphabetical order.
Rails.application.config.x.book_submissions = ActiveSupport::OrderedOptions.new.merge(
  # Submissions one reader may make in a rolling 24 hours.
  daily_limit: 20,
  # Lookup jobs the day may start; BOOK_SUBMISSION_LOOKUP_RUNS overrides it.
  lookup_runs_per_day: GoodreadsEnv.integer("BOOK_SUBMISSION_LOOKUP_RUNS", 100),
  # BOOK_SUBMISSION_LOOKUPS_ENABLED=0 stops the lookup jobs without a deploy.
  lookups_enabled: GoodreadsEnv.boolean("BOOK_SUBMISSION_LOOKUPS_ENABLED", true),
  # How long a request waits before the lookup tries it again.
  retry_window: 1.hour
)
