# frozen_string_literal: true

# Member Goodreads imports (Goodreads import spec §4, §10). Rails config, not
# an admin UI.
Rails.application.config.x.goodreads_imports = ActiveSupport::OrderedOptions.new.merge(
  # The largest legacy upload was 8.1 MB.
  max_file_bytes: 10.megabytes,
  # Imports a user may start in any 24 hours.
  daily_limit: 3,
  # One email per finished or failed member import.
  notify_to: "contact@thegreatestbooks.org",
  # An import in progress for longer than this is flagged stuck on the admin
  # page and can be run again.
  stuck_after: 2.hours.to_i
)
