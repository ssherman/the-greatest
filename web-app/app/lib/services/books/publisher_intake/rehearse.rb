# frozen_string_literal: true

module Services
  module Books
    module PublisherIntake
      # Development aid: runs one source's whole pipeline once, synchronously, so
      # a strategy can be tried against the live site by hand. It runs the
      # discovery requests first-in first-out (the strategy's own, then its seed
      # requests; follow-ups go to the end of the line) into a manual run, then
      # reads up to limit pending listings, and prints one line per fetch (URL,
      # outcome, elapsed time) and a summary. It prints no page content.
      #
      # It does not use the source's gate, Sidekiq or the enabled setting, and
      # counts nothing against the daily cap: it waits settings.fetch_interval
      # seconds between fetches itself, which makes it the one place in the
      # feature that sleeps (sleeper: is for tests). It refuses to run in
      # production, before it creates or fetches anything.
      #
      # The run is saved as finished only when every discovery request ran to
      # the end. A rehearsal cut short by max_discovery_requests, or one that
      # met a request that did not parse, is saved as failed, so it never counts
      # as the source's finished first run.
      #
      # data: {requests:, listings_seen:, read:, outcomes: {found: n, ...}, held: {reason: n}}
      class Rehearse
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(source:, limit:, max_discovery_requests: nil, out: $stdout, sleeper: Kernel.method(:sleep))
          new(source: source, limit: limit, max_discovery_requests: max_discovery_requests, out: out, sleeper: sleeper).call
        end

        def initialize(source:, limit:, max_discovery_requests:, out:, sleeper:)
          @strategy = source
          @limit = limit.to_i
          @max_given = !max_discovery_requests.nil?
          # Integer() would truncate a Float; only an Integer or a numeric string is a count.
          @max_requests = Integer(max_discovery_requests, exception: false) if max_discovery_requests.is_a?(Integer) || max_discovery_requests.is_a?(String)
          @out = out
          @sleeper = sleeper
          @fetched = false
          @summary = {requests: 0, listings_seen: 0, read: 0, outcomes: Hash.new(0), held: Hash.new(0)}
        end

        def call
          return Result.new(success?: false, data: nil, errors: ["rehearse does not run in production"]) if Rails.env.production?

          if @max_given && !@max_requests&.positive?
            return Result.new(success?: false, data: nil, errors: ["max_discovery_requests must be a positive integer"])
          end

          @out.puts("rehearsing #{@strategy.key}")
          @run = start_run
          begin
            discovery_ok = discover
            read_listings if discovery_ok
          ensure
            # An interrupted or raising rehearsal must not leave a running run,
            # which would stop the weekly job starting this source. The
            # exception goes on; only its class is recorded.
            fail_unfinished_run
          end
          @out.puts("requests #{@summary[:requests]}, listings seen #{@summary[:listings_seen]}, read #{@summary[:read]}, " \
            "outcomes #{@summary[:outcomes].to_h}, held #{@summary[:held].to_h}, run #{@run.status}")
          Result.new(success?: true, data: @summary.merge(outcomes: @summary[:outcomes].to_h, held: @summary[:held].to_h), errors: [])
        end

        private

        def start_run
          first_run = !::Books::PublisherIntakeRun.where(source: @strategy.key, status: :finished).exists?
          ::Books::PublisherIntakeRun.create!(source: @strategy.key, kind: :manual, status: :running, started_at: Time.current,
            baseline: first_run && @strategy.baseline_on_first_run?, counts: {"requests" => 0, "outstanding" => 0})
        end

        def fail_unfinished_run
          return unless @run.reload.status_running?

          @run.update!(status: :failed, finished_at: Time.current, error: "rehearsal ended early: #{$!&.class&.name || "unknown"}")
        end

        # Returns false when a request did not parse or was not answered, in
        # which case nothing more is fetched.
        def discover
          queue = @strategy.discovery_requests(since: nil) +
            @strategy.seed_requests.map { |r| r.with(context: r.context.merge("seed" => true)) }

          until queue.empty?
            if @max_requests && @summary[:requests] >= @max_requests
              return save_run(:failed, "stopped after #{@summary[:requests]} discovery requests")
            end

            request = queue.shift
            response, failure = fetch(request)
            @summary[:requests] += 1
            return save_run(:failed, "#{request.url}: #{failure}") if failure

            discovery = parse_discovery(request, response)
            unless discovery&.outcome == :ok
              outcome = discovery ? discovery.outcome : :unparseable
              @out.puts("  discovery outcome #{outcome}")
              return save_run(:failed, "#{request.url}: #{outcome}")
            end

            recorded = RecordDiscovery.call(run: @run, listings: discovery.listings, seed: request.context["seed"] == true)
            @summary[:listings_seen] += recorded.data[:seen]
            # As DiscoveryRequestJob does: a seed request's follow-ups are seeds too.
            follow_ups = discovery.requests
            follow_ups = follow_ups.map { |r| r.with(context: r.context.merge("seed" => true)) } if request.context["seed"] == true
            queue.concat(follow_ups)
          end
          save_run(:finished, nil)
          true
        end

        # Records the run's end. :finished returns true; a cut-short or broken
        # run returns whether reading may go on (only a cut-short one may).
        def save_run(status, error)
          @run.update!(status: status, finished_at: Time.current, error: error,
            counts: (@run.reload.counts || {}).merge("requests" => @summary[:requests], "outstanding" => 0))
          status == :finished || error.to_s.start_with?("stopped after")
        end

        def read_listings
          ids = ::Books::PublisherListing.where(source: @strategy.key, state: :pending).order(:id).limit(@limit).pluck(:id)
          ids.each do |id|
            listing = ::Books::PublisherListing.find(id)
            next unless listing.state_pending?

            response, failure = fetch(@strategy.listing_request(listing))
            if failure
              store(listing, ::Books::PublisherIntake::Reading.new(outcome: failure, facts: nil, sibling_keys: []), nil)
              break if failure == :fetcher_down

              next
            end

            reading = parse_listing(listing, response)
            outcome = store(listing, reading, response.is_a?(::PageFetcher::Page) ? response : nil)
            break if outcome == :blocked
          end
        end

        def store(listing, reading, page)
          stored = StoreReading.call(listing: listing, reading: reading, page: page, parser_version: @strategy.parser_version)
          outcome = stored.data[:outcome]
          @out.puts("  outcome #{outcome}")
          @summary[:read] += 1
          @summary[:outcomes][outcome] += 1
          title = stored.data[:title]
          @summary[:held][title.hold_reason.to_sym] += 1 if title&.status_held?
          outcome
        end

        # One fetch, with the wait before it (none before the first), and its
        # line. Returns [response, nil] or [nil, failure].
        def fetch(request)
          @sleeper.call(::Books::PublisherIntake.settings.fetch_interval) if @fetched
          @fetched = true
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          response, failure = FetchRequest.call(request)
          elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
          @out.puts("#{request.url} #{failure || (response.respond_to?(:status) ? "status #{response.status}" : "answered")} #{elapsed}ms")
          [response, failure]
        end

        def parse_discovery(request, response)
          @strategy.parse_discovery(request: request, response: response)
        rescue => e
          Rails.logger.warn("PublisherIntake: rehearsal of #{@strategy.key} discovery parser raised #{e.class.name}")
          nil
        end

        def parse_listing(listing, response)
          @strategy.parse_listing(listing: listing, page: response)
        rescue => e
          Rails.logger.warn("PublisherIntake: rehearsal of #{@strategy.key} listing #{listing.id} parser raised #{e.class.name}")
          ::Books::PublisherIntake::Reading.new(outcome: :unparseable, facts: nil, sibling_keys: [])
        end
      end
    end
  end
end
