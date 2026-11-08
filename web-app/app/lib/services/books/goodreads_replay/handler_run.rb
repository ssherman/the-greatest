# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      # What the two verdict appliers (ApplyVerdicts and GoodreadsReimport::Apply) share: running a handler
      # through the deadlock retry, and queueing the ranking and favorites follow-ups once per run.
      module HandlerRun
        POSTGRES_ERRORS = [ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished].freeze
        DEADLOCK_ATTEMPTS = 3

        private

        # The merges defer their per-merge requests, so a run of thousands of
        # merges asks for each configuration once. Every refresh reweighs before
        # it ranks, so a configuration a merge touched and one only a provisional
        # flag touched get the same request. Sorted so the request is
        # deterministic.
        def queue_follow_ups(configuration_ids, follow_ups)
          ::Services::RankingConfigurations::RequestRefresh.call_for_ids(configuration_ids.to_a.sort, delay: 5.minutes)
          ::GenerateUserFavoritesListsJob.perform_async("Books::UserList") if follow_ups.include?(:user_favorites)
          request_author_rankings if follow_ups.include?(:author_rankings)
        end

        def request_author_rankings
          authors = ::Books::Authors::RankingConfiguration.default_primary
          ::Services::RankingConfigurations::RequestRefresh.call(config: authors, delay: 5.minutes) if authors
        end

        # Enrichment jobs running alongside apply update the same rows (a country's book_count, say), so
        # Postgres sometimes kills apply's transaction to break a deadlock. That attempt rolled back, and every
        # handler is safe to re-run, so the verdict is tried again from its stored state; the in-memory copy
        # may still hold what the rolled-back attempt wrote. Still deadlocked after that, the run stops.
        def call_handler(verdict, handler)
          attempt = 1
          begin
            handler.call(verdict: verdict)
          rescue ActiveRecord::Deadlocked
            raise if attempt >= DEADLOCK_ATTEMPTS
            sleep(attempt)
            attempt += 1
            verdict.reload
            retry
          end
        end
      end
    end
  end
end
