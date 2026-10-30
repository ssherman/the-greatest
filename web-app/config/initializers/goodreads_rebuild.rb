# frozen_string_literal: true

# The Goodreads rebuild's enrichment of fixed books (Services::Books::GoodreadsRebuild::QueueEnrichment).
# Rails config, not an admin UI; the ENV name lets it change without a deploy.
Rails.application.config.x.goodreads_rebuild = ActiveSupport::OrderedOptions.new.merge(
  # Fixed books allowed to wait for their Goodreads fetch at once. The top-up job
  # (every 10 minutes) starts more as they finish, so the line stays full without
  # swamping the fetch queue that other books share.
  in_flight: Integer(ENV.fetch("GOODREADS_REBUILD_IN_FLIGHT", 300))
)
