# frozen_string_literal: true

module Wikidata
  module Exceptions
    class ConfigurationError < ::Wikimedia::Exceptions::Error; end

    # The local Wikidata service cannot answer right now: connection refused,
    # a timeout, a 5xx, or an open circuit. A RateLimited, so the jobs that
    # already reschedule on a Wikimedia wait reschedule on this too, instead
    # of failing; the service coming back is the same kind of event.
    class Unavailable < ::Wikimedia::Exceptions::RateLimited
      RETRY_AFTER = 300

      def initialize(message, retry_after: RETRY_AFTER)
        super
      end
    end

    # The service answered, and the answer is not usable: a 4xx (we sent
    # something it refuses) or a body that is not JSON.
    class ServiceError < ::Wikimedia::Exceptions::Error
      attr_reader :status_code

      def initialize(message, status_code = nil)
        super(message)
        @status_code = status_code
      end
    end
  end
end
