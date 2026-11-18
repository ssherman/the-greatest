# frozen_string_literal: true

module Services
  module Books
    module PublisherIntake
      # Reads one pending listing: takes its turn at the source's gate, fetches
      # the page the strategy asks for, hands it to the strategy's parser and
      # stores the reading (publisher intake design §3 and §4). It never blocks a thread:
      # a :wait is the job's to reschedule.
      #
      # data: {action:, wait:, outcome:}
      # - action :done, a fetch was attempted and its outcome stored (outcome is
      #   :fetcher_down when nothing reached the site);
      # - :wait, the turn is not due yet, wait seconds (the job reschedules with
      #   due true; a :refused read is never rescheduled, the sweep re-queues it);
      # - :refused, the gate is spent or blocked: the listing stays pending and
      #   its queue mark is cleared, so the sweep queues it again;
      # - :skipped, nothing to do: the listing is no longer pending (reading a
      #   sibling format can cover it while its own job waits) or its source is
      #   switched off or unregistered. Skipping takes no gate turn.
      class ReadListing
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(listing:, due: false)
          new(listing: listing, due: due).call
        end

        def initialize(listing:, due:)
          @listing = listing
          @due = due
        end

        def call
          return skipped unless @listing.state_pending?
          return skipped unless enabled?

          strategy = ::Books::PublisherIntake::Sources.fetch(@listing.source)
          gate = ::Books::PublisherIntake.gate_for(@listing.source)
          turn = ::Books::Goodreads::GateTurn.call(gate: gate, due: @due)
          case turn.action
          when :refused
            @listing.update!(queued_at: nil)
            return done(:refused)
          when :wait
            return done(:wait, wait: turn.wait)
          end

          response, failure = FetchRequest.call(strategy.listing_request(@listing))
          return store_failure(failure) if failure

          reading = parse(strategy, response)
          # StoreReading keeps a page's HTML; a file response has none to keep.
          stored = StoreReading.call(listing: @listing, reading: reading, page: response.is_a?(::PageFetcher::Page) ? response : nil,
            parser_version: strategy.parser_version)
          outcome = stored.data[:outcome]
          ::Books::Goodreads::GateTurn.after_fetch(gate: gate, outcome: outcome)
          done(:done, outcome: outcome)
        end

        private

        # A strategy that raises is a page it cannot read: unparseable, stored
        # with the page like any other. Only the class name is logged: the
        # message can carry page text.
        def parse(strategy, response)
          strategy.parse_listing(listing: @listing, page: response)
        rescue => e
          Rails.logger.warn("PublisherIntake: #{@listing.source} listing #{@listing.id} parser raised #{e.class.name}")
          ::Books::PublisherIntake::Reading.new(outcome: :unparseable, facts: nil, sibling_keys: [])
        end

        def enabled?
          ::Books::PublisherIntake.settings.enabled_sources.include?(@listing.source) &&
            ::Books::PublisherIntake::Sources.fetch(@listing.source).present?
        end

        # :fetcher_down never reached the site and :unavailable got no answer;
        # StoreReading owns what each changes on the listing.
        def store_failure(outcome)
          reading = ::Books::PublisherIntake::Reading.new(outcome: outcome, facts: nil, sibling_keys: [])
          strategy = ::Books::PublisherIntake::Sources.fetch(@listing.source)
          StoreReading.call(listing: @listing, reading: reading, page: nil, parser_version: strategy.parser_version)
          done(:done, outcome: outcome)
        end

        def skipped = done(:skipped)

        def done(action, wait: nil, outcome: nil)
          Result.new(success?: true, data: {action: action, wait: wait, outcome: outcome}, errors: [])
        end
      end
    end
  end
end
