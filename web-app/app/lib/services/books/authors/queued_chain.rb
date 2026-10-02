# frozen_string_literal: true

require "sidekiq/api"

module Services
  module Books
    module Authors
      # The authors with an author-chain job waiting in Sidekiq: scheduled,
      # waiting to retry, or enqueued on the low queue. A job running at this
      # moment is in none of these and is missed; the backfill accepts that.
      # Reads each set whole, so a pass costs about a second per ten thousand
      # jobs.
      class QueuedChain
        JOBS = %w[Books::Authors::WikidataJob Books::Authors::ViafJob Books::Authors::EnrichJob].freeze
        QUEUE = "low"

        def self.by_job
          found = JOBS.index_with { [] }
          [::Sidekiq::ScheduledSet.new, ::Sidekiq::RetrySet.new, ::Sidekiq::Queue.new(QUEUE)].each do |source|
            source.each { |job| found[job.klass] << job.args.first.to_i if found.key?(job.klass) }
          end
          found
        end

        def self.author_ids = by_job.values.flatten.to_set
      end
    end
  end
end
