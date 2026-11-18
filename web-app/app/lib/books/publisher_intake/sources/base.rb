# frozen_string_literal: true

module Books
  module PublisherIntake
    module Sources
      # A strategy never fetches, stores or enqueues: it says what to fetch and
      # reads what came back. Subclasses define key, name, VERSION and the
      # request/parse methods.
      class Base
        def key = raise(NotImplementedError)

        def name = raise(NotImplementedError)

        def parser_version = self.class::VERSION

        # true for list-comparison sources, whose first run records what exists.
        def baseline_on_first_run? = false

        def discovery_requests(since:) = raise(NotImplementedError)

        def seed_requests = []

        def parse_discovery(request:, response:) = raise(NotImplementedError)

        def listing_request(listing) = raise(NotImplementedError)

        def parse_listing(listing:, page:) = raise(NotImplementedError)

        # nil means the status carries no verdict of its own.
        def status_outcome(status)
          case status
          when 404, 410 then :not_found
          when 401, 403, 429 then :blocked
          when 500.. then :unavailable
          end
        end

        def in_window?(date)
          return false if date.nil?

          settings = ::Books::PublisherIntake.settings
          today = Date.current
          date = date.to_date
          date.between?(today - settings.lookback_days, today + settings.horizon_days)
        end
      end
    end
  end
end
