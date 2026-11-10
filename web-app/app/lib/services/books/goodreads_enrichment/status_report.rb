# frozen_string_literal: true

module Services
  module Books
    module GoodreadsEnrichment
      # A plain-text answer to "is Goodreads fetching, and is it working?"
      # (books:goodreads:status): the fetch gate, what the last day's fetches
      # stored, and where the goodreads workflow steps stand. Read-only.
      #
      # Fetches that stored nothing (Goodreads' 503 page, a timeout, a down
      # fetcher) are not in the tables; the worker log has one "Goodreads
      # fetch:" line for each one that reached Goodreads.
      class StatusReport
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        WINDOW = 24.hours
        STEP_KEY = "goodreads"

        def self.call(gate: nil)
          new(gate: gate || ::Books::Goodreads::FetchGate.new).call
        end

        def initialize(gate:)
          @gate = gate
        end

        def call
          lines = ["Goodreads status at #{Time.current.utc.strftime("%Y-%m-%d %H:%M UTC")}", ""]
          lines.concat(gate_lines, [""], fetch_lines, [""], step_lines)
          Result.new(success?: true, data: {report: lines.join("\n")}, errors: [])
        end

        private

        def config = Rails.application.config.x.goodreads

        def since = (@since ||= WINDOW.ago)

        def gate_lines
          blocked = @gate.blocked_until
          usage = @gate.usage
          state = blocked ? "BLOCKED until #{blocked.utc.strftime("%Y-%m-%d %H:%M UTC")}" : "open"
          day = usage.day ? "#{usage.day.iso8601}: #{usage.count} of #{config.daily_fetch_cap} fetches reserved" : "no fetches reserved"
          ["Fetch gate: #{state}", "  #{day}"]
        end

        def fetch_lines
          pages = ::Books::GoodreadsPage.where(source: :fetched).where(fetched_at: since..).group(:outcome).count
          searches = ::Books::GoodreadsSearch.where(fetched_at: since..).group(:outcome).count
          last = [::Books::GoodreadsPage.where(source: :fetched).maximum(:fetched_at), ::Books::GoodreadsSearch.maximum(:fetched_at)].compact.max
          ["Stored in the last 24 hours (503s and timeouts store nothing; grep the worker log for \"Goodreads fetch:\"):",
            "  book pages: #{counts(pages)}",
            "  searches:   #{counts(searches)}",
            "  last stored fetch: #{last ? "#{last.utc.strftime("%Y-%m-%d %H:%M UTC")} (#{ago(last)})" : "never"}"]
        end

        def step_lines
          steps = ::WorkflowStep.where(key: STEP_KEY)
          open_states = steps.where(state: %i[blocked ready running waiting]).group(:state).count
          finished = steps.where(finished_at: since..)
          outcomes = finished.succeeded.group(:outcome).count
          failed = finished.failed.pluck(:error).map { |error| error.to_s[/failed: (\w+)\z/, 1] || error.to_s.truncate(60) }.tally
          ["Goodreads steps:",
            "  open now: #{counts(open_states)}",
            "  succeeded in the last 24 hours: #{counts(outcomes)}",
            "  failed in the last 24 hours (attempts used up): #{counts(failed)}",
            "  failed, all time: #{steps.failed.count}"]
        end

        def counts(hash)
          return "none" if hash.empty?

          hash.sort_by { |key, count| [-count, key.to_s] }.map { |key, count| "#{key || "unknown"} #{count}" }.join(", ")
        end

        def ago(time)
          "#{ActionController::Base.helpers.time_ago_in_words(time)} ago"
        end
      end
    end
  end
end
