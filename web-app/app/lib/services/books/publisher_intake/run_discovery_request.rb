# frozen_string_literal: true

module Services
  module Books
    module PublisherIntake
      # Performs one discovery request of a run (publisher intake design §3):
      # takes its turn at the source's gate, fetches, hands the response to the
      # strategy's parse_discovery and records what it found. It never blocks a thread.
      #
      # data: {action:, wait:, outcome:, requests:}
      # - action :done, with the follow-up requests to enqueue (none when the
      #   run was failed here: its status is then failed, and the job must not
      #   count the request);
      # - :wait, reschedule for wait seconds with the turn marked due;
      # - :retry, no answer yet and attempts remain;
      # - :skipped, the run is not running or its source is switched off.
      #
      # A response body never reaches the run's error: it names the request URL
      # and the outcome only.
      class RunDiscoveryRequest
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        MIN_REOPEN_WAIT = 60

        def self.call(run:, request:, due: false, attempt: 1)
          new(run: run, request: request, due: due, attempt: attempt).call
        end

        def initialize(run:, request:, due:, attempt:)
          @run = run
          @request = request
          @due = due
          @attempt = attempt
        end

        def call
          return skipped unless @run.status_running?
          return skipped unless enabled?

          @strategy = ::Books::PublisherIntake::Sources.fetch(@run.source)
          @gate = ::Books::PublisherIntake.gate_for(@run.source)
          turn = ::Books::Goodreads::GateTurn.call(gate: @gate, due: @due)
          case turn.action
          when :wait then return result(:wait, wait: turn.wait)
          when :refused then return result(:wait, wait: until_reopened)
          end

          response, failure = FetchRequest.call(@request)
          return no_answer(failure) if failure

          discovery = @strategy.parse_discovery(request: @request, response: response)
          case discovery.outcome
          when :ok then record(discovery)
          when :blocked
            @gate.block!
            result(:wait, wait: until_reopened, outcome: :blocked)
          when :unavailable then no_answer(:unavailable)
          else fail_run(discovery.outcome)
          end
        end

        private

        def enabled?
          ::Books::PublisherIntake.settings.enabled_sources.include?(@run.source) &&
            ::Books::PublisherIntake::Sources.fetch(@run.source).present?
        end

        def record(discovery)
          RecordDiscovery.call(run: @run, listings: discovery.listings, seed: @request.context["seed"] == true)
          result(:done, outcome: :ok, requests: discovery.requests)
        end

        def no_answer(outcome)
          return result(:retry, outcome: outcome) if @attempt < ::Books::PublisherIntake.settings.fetch_attempts

          fail_run(outcome)
        end

        def fail_run(outcome)
          @run.update!(status: :failed, finished_at: Time.current, error: "#{@request.url}: #{outcome}")
          result(:done, outcome: outcome)
        end

        # The gate reopened between the refusal and this check when reopens_at
        # is nil; a minute is then a safe pause before asking again.
        def until_reopened
          reopens_at = @gate.reopens_at
          return MIN_REOPEN_WAIT if reopens_at.nil?

          [(reopens_at - Time.current).ceil, MIN_REOPEN_WAIT].max
        end

        def skipped = result(:skipped)

        def result(action, wait: nil, outcome: nil, requests: [])
          Result.new(success?: true, data: {action: action, wait: wait, outcome: outcome, requests: requests}, errors: [])
        end
      end
    end
  end
end
