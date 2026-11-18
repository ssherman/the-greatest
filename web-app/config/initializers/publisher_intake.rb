# frozen_string_literal: true

# Publisher intake settings. Self-contained like goodreads.rb: app constants cannot
# be referenced while Rails boots (see doorkeeper.rb), so there is no settings class
# under app/lib. GoodreadsEnv.integer is already loaded because goodreads.rb sorts first.
module PublisherIntakeEnv
  # "a, b ,,a" -> ["a", "b"]. Blank or nil means no sources.
  def self.sources(raw)
    raw.to_s.split(",").map(&:strip).reject(&:empty?).uniq
  end
end

Rails.application.config.x.publisher_intake = ActiveSupport::OrderedOptions.new.merge(
  # Catalog source keys the weekly run reads. Empty means the feature does nothing.
  enabled_sources: PublisherIntakeEnv.sources(ENV["PUBLISHER_INTAKE_SOURCES"]),
  # Seconds from one fetch start to the next. PUBLISHER_INTAKE_FETCH_INTERVAL overrides it.
  fetch_interval: GoodreadsEnv.integer("PUBLISHER_INTAKE_FETCH_INTERVAL", 10),
  # Fetches reserved per UTC day. PUBLISHER_INTAKE_DAILY_FETCH_CAP overrides it.
  daily_fetch_cap: GoodreadsEnv.integer("PUBLISHER_INTAKE_DAILY_FETCH_CAP", 2_000),
  # How long a block stops every fetch for a source.
  block_cooldown: 6.hours.to_i,
  # Tries for a fetch that got no answer before it is given up.
  fetch_attempts: 3,
  # Days between runs.
  run_every_days: 7,
  # Days before a title already held is read again.
  reread_after_days: 28,
  # Titles published this many days ago or later are in scope.
  lookback_days: 30,
  # Titles publishing within this many days ahead are in scope.
  horizon_days: 365,
  # A run still going after this many days is treated as stuck.
  stuck_run_days: 3,
  fetch_timeout_ms: 30_000
)
