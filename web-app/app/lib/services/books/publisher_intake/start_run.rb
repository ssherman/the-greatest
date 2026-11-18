# frozen_string_literal: true

module Services
  module Books
    module PublisherIntake
      # Starts a discovery run for one source and enqueues its first requests
      # (publisher intake design §3 and §5). Nothing is fetched here.
      #
      # "First run" means every run until one of the source's runs has finished:
      # a baseline source records what exists on those runs, and every source
      # also fetches its seed requests. The run is saved with its counts before
      # any job is enqueued, because each DiscoveryRequestJob decrements
      # counts["outstanding"] and finishes the run at zero.
      #
      # data: {run:}
      class StartRun
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(source:, kind: :weekly)
          new(source: source, kind: kind).call
        end

        def initialize(source:, kind:)
          @source = source
          @kind = kind
        end

        def call
          finished = ::Books::PublisherIntakeRun.where(source: @source.key, status: :finished)
          last_finished = finished.order(:started_at, :id).last
          first_run = last_finished.nil?

          requests = @source.discovery_requests(since: last_finished&.started_at)
          requests += @source.seed_requests.map { |r| r.with(context: r.context.merge("seed" => true)) } if first_run

          now = Time.current
          run = ::Books::PublisherIntakeRun.create!(
            source: @source.key, kind: @kind, baseline: first_run && @source.baseline_on_first_run?,
            status: requests.empty? ? :finished : :running, started_at: now,
            finished_at: requests.empty? ? now : nil,
            counts: {"requests" => requests.size, "outstanding" => requests.size}
          )
          requests.each { |request| ::Books::PublisherIntake::DiscoveryRequestJob.perform_async(run.id, request.to_h) }

          Result.new(success?: true, data: {run: run}, errors: [])
        end
      end
    end
  end
end
