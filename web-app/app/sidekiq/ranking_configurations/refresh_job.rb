# frozen_string_literal: true

# Recalculates one ranking configuration -- global or member-owned -- as one
# unit of work: list weights first, then item rankings, so the ranking never
# reads weights a separate job has not finished yet. Always queued through
# Services::RankingConfigurations::RequestRefresh, whose claim on the row is
# what keeps a burst of triggers down to one run.
#
# Status lives on the configuration row (RankingConfiguration#refresh_status),
# which is why this never retries -- the next request is the retry, and a
# Sidekiq retry would rerun invisibly while the row still said "failed".
#
# A run starts only from `queued`. A stale claim can put a second job in the
# queue while the first is still waiting or working, and that second job must
# not calculate alongside it. Starting also stamps refresh_requested_at, so the
# stale window RequestRefresh measures counts from when the run began, not from
# when it was queued: a job that waited most of an hour must not look wedged a
# few minutes into its own run.
#
# needs_refresh is cleared when the run STARTS, not when it ends: an edit made
# while this job is running (Save, AddLists, remove) sets it back to true, and
# the run in flight is computing from data that no longer matches, so the
# successful-end update must never touch it -- otherwise it would stomp the
# edit's true back to false and the page would claim "Up to date" for
# rankings computed from stale, pre-edit data. A failure sets it back to true
# unconditionally, since whatever it was computing didn't land either way.
#
# Only the books default primary feeds the author rankings and the ranked
# fields in the search index, so only it requests them. A member's ranking or
# a year rollup finishing must trigger neither.
module RankingConfigurations
  class RefreshJob
    include Sidekiq::Job

    sidekiq_options queue: :low, retry: false

    def perform(ranking_configuration_id)
      config = ::RankingConfiguration.find_by(id: ranking_configuration_id)
      return if config.nil? # deleted while queued -- not a failure
      started = start(config)
      unless started
        Rails.logger.info "[RankingConfigurations::RefreshJob] configuration #{ranking_configuration_id}: run skipped, the row was not queued (another job holds it, or nothing requested one)"
        return
      end

      weights = Rankings::BulkWeightCalculator.new(config).call
      if weights[:errors].any?
        first = weights[:errors].first
        raise "Weight calculation failed for #{weights[:errors].size} list(s): #{first[:list_name]}: #{first[:error]}"
      end

      result = config.calculate_rankings
      raise "Ranking calculation failed: #{result.errors.join(", ")}" unless result.success?

      # Before the row goes idle: a shutdown among the follow-ups still finds it
      # `running`, hands it back, and the pushed-back job requests them again.
      # None of them reads refresh_status, and each has its own rescue.
      request_primary_follow_ups(config)
      request_csv_regenerate(config)

      config.update_columns(
        refresh_status: ::RankingConfiguration.refresh_statuses[:idle],
        last_refreshed_at: Time.current,
        last_refresh_error: nil
      )
    rescue ::Sidekiq::Shutdown
      # Sidekiq has already pushed this job back onto the queue, and the pushed-back
      # copy only runs from `queued`. Hand the row back (only if it is still ours,
      # i.e. `running`) or it stays wedged until the stale window expires.
      if started
        ::RankingConfiguration.where(id: ranking_configuration_id, refresh_status: ::RankingConfiguration.refresh_statuses[:running])
          .update_all(refresh_status: ::RankingConfiguration.refresh_statuses[:queued])
      end
      raise
    rescue => e
      Rails.logger.error "[RankingConfigurations::RefreshJob] configuration #{ranking_configuration_id}: #{e.message}"
      ::RankingConfiguration.where(id: ranking_configuration_id).update_all(
        refresh_status: ::RankingConfiguration.refresh_statuses[:failed],
        needs_refresh: true,
        last_refresh_error: e.message.truncate(500)
      )
    end

    private

    # queued -> running in one conditional UPDATE (restamping the clock the
    # stale check reads); false means another job already holds this run, or
    # nothing asked for one.
    def start(config)
      statuses = ::RankingConfiguration.refresh_statuses
      ::RankingConfiguration.where(id: config.id, refresh_status: statuses[:queued])
        .update_all(refresh_status: statuses[:running], needs_refresh: false, refresh_requested_at: Time.current) == 1
    end

    # Each follow-up is attempted on its own, so a failed author request (a DB
    # blip in its claim) cannot cost the reindex as well.
    def request_primary_follow_ups(config)
      books_primary = follow_up(config, "primary check") { config.type == "Books::RankingConfiguration" && config.default_primary? }
      return unless books_primary

      follow_up(config, "author rankings refresh") do
        authors = ::Books::Authors::RankingConfiguration.default_primary
        ::Services::RankingConfigurations::RequestRefresh.call(config: authors) if authors
      end
      follow_up(config, "ranked-fields reindex") { ::Books::ReindexRankedFieldsJob.perform_async }
    end

    # rerun_if_generating: a run already in flight plucked its ids before
    # these ranks landed, so it must go again when it finishes.
    def request_csv_regenerate(config)
      follow_up(config, "CSV regenerate") do
        ::Services::CsvExports::RequestGenerate.call(ranking_configuration: config, rerun_if_generating: true)
      end
    end

    # Follow-ups are side effects of the refresh, not part of it: the ranking
    # already landed, and a failure here must not flip the row to "failed".
    # Logged rather than raised -- retry: false means a raise would only be
    # logged anyway, and the next request (or the nightly jobs) catch up.
    # Sidekiq::Shutdown is not a StandardError and passes through, so the
    # hand-back in #perform still sees it.
    def follow_up(config, what)
      yield
    rescue => e
      Rails.logger.error "[RankingConfigurations::RefreshJob] configuration #{config.id}: #{what} not requested: #{e.message}"
      nil
    end
  end
end
