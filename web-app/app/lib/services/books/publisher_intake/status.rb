# frozen_string_literal: true

module Services
  module Books
    module PublisherIntake
      # What the operator wants to know about publisher intake: per source, the
      # last run, listings by state, titles by status and hold reason, and the
      # day's fetch count against the cap. Covers every registered source and
      # every source key found in the tables (registered: false for the
      # latter, whose rows outlive its strategy). Reads the tables and Redis.
      #
      # data: {sources: [{key:, name:, enabled:, registered:, last_run:, listings:, titles:, fetches_today:,
      #   daily_cap:, blocked_until:}]}
      class Status
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call = new.call

        def call
          registry = ::Books::PublisherIntake::Sources.registry
          keys = (registry.keys + table_keys).uniq
          Result.new(success?: true, data: {sources: keys.map { |key| describe(key, registry[key]) }}, errors: [])
        end

        private

        def table_keys
          [::Books::PublisherListing, ::Books::PublisherTitle, ::Books::PublisherIntakeRun].flat_map { |m| m.distinct.pluck(:source) }.sort
        end

        def describe(key, strategy_class)
          settings = ::Books::PublisherIntake.settings
          gate = ::Books::PublisherIntake.gate_for(key)
          {
            key: key,
            name: strategy_class ? strategy_class.new.name : key,
            enabled: settings.enabled_sources.include?(key),
            registered: strategy_class.present?,
            last_run: last_run(key),
            listings: ::Books::PublisherListing.where(source: key).group(:state).count.transform_keys(&:to_sym),
            titles: titles(key),
            fetches_today: fetches_today(gate),
            daily_cap: settings.daily_fetch_cap,
            blocked_until: gate.blocked_until
          }
        end

        # The gate's usage names the UTC day of its newest reservation, which can
        # be tomorrow or an old day: only a count for today is today's.
        def fetches_today(gate)
          usage = gate.usage
          (usage.day == Time.now.utc.to_date) ? usage.count : 0
        end

        def last_run(key)
          run = ::Books::PublisherIntakeRun.where(source: key).order(:started_at, :id).last
          run && {id: run.id, kind: run.kind, status: run.status, started_at: run.started_at, finished_at: run.finished_at,
                  counts: run.counts, error: run.error}
        end

        def titles(key)
          scope = ::Books::PublisherTitle.where(source: key)
          {ready: scope.status_ready.count,
           held: scope.status_held.group(:hold_reason).count.transform_keys(&:to_sym)}
        end
      end
    end
  end
end
