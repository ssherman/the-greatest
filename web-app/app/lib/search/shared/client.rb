# frozen_string_literal: true

module Search
  module Shared
    class Client
      class << self
        def instance
          @instance ||= OpenSearch::Client.new(
            host: ENV.fetch("OPENSEARCH_URL"),
            log: Rails.env.development?,
            trace: Rails.env.development?
          )
        end

        def reset!
          @instance = nil
        end

        def health
          instance.cluster.health
        end

        def cluster_info
          instance.info
        end

        def ping
          instance.ping
        rescue
          false
        end
      end
    end
  end
end
