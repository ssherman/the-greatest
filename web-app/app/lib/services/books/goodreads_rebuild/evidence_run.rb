# frozen_string_literal: true

module Services
  module Books
    module GoodreadsRebuild
      # Survey pass 2 over every derived book's editions that have no evidence
      # yet (rebuild spec §4.2), N threads at a time, each with its own
      # clients and connection. Meant for Shane's PC against local Open
      # Library and WorldCat instances: it refuses unless both service URLs
      # are local, so it can never load the shared home-server services the
      # production runs use. A service error stops the run; evidence already
      # written stays and a re-run skips it.
      class EvidenceRun
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        NOT_LOCAL = "point OPEN_LIBRARY_SERVICE_URL and WORLDCAT_SERVICE_URL at local instances"
        LOCAL_HOSTS = %w[localhost 127.0.0.1].freeze
        PROGRESS_EVERY = 1_000
        # Seconds to wait before each retry of an edition whose lookup failed.
        # A saturated local WorldCat answers 504 past its own deadline; it
        # recovers once the queue drains.
        PAUSES = [10, 30, 90].freeze
        SERVICE_ERRORS = [::Books::OpenLibrary::Exceptions::Error, ::Books::WorldCat::Exceptions::Error].freeze

        def self.call(threads: 4, limit: nil, force: false, sleeper: ->(seconds) { sleep(seconds) })
          new(threads: threads, limit: limit, force: force, sleeper: sleeper).call
        end

        def initialize(threads:, limit:, force:, sleeper:)
          @threads = threads
          @limit = limit
          @force = force
          @sleeper = sleeper
          @looked_up = 0
          @mutex = Mutex.new
        end

        def call
          return result(stopped: true, error: NOT_LOCAL) unless @force || local_services?

          queue = Queue.new
          edition_ids.each { |id| queue << id }
          workers = Array.new(@threads) { Thread.new { work(queue) } }
          workers.each(&:join)
          result(stopped: !@error.nil?, error: @error)
        end

        private

        def local_services?
          [::Books::OpenLibrary::Configuration.new.base_url, ::Books::WorldCat::Configuration.new.base_url].all? do |url|
            LOCAL_HOSTS.include?(URI.parse(url.to_s).host)
          end
        end

        def work(queue)
          ::ActiveRecord::Base.connection_pool.with_connection do
            world_cat = ::Books::WorldCat::Client.new
            open_library = ::Books::OpenLibrary::Client.new
            while (id = next_id(queue))
              edition = ::Books::GoodreadsEdition.find_by(id: id)
              next unless edition

              gather(edition, world_cat, open_library)
              count
            end
          end
        rescue *SERVICE_ERRORS => e
          @mutex.synchronize { @error ||= "#{e.class}: #{e.message}" }
          queue.clear
        end

        def gather(edition, world_cat, open_library)
          attempt = 0
          begin
            GatherEvidence.call(edition: edition, world_cat: world_cat, open_library: open_library)
          rescue *SERVICE_ERRORS
            raise if attempt >= PAUSES.size || @error

            @sleeper.call(PAUSES[attempt])
            attempt += 1
            retry
          end
        end

        def next_id(queue)
          return nil if @error

          queue.pop(true)
        rescue ThreadError
          nil
        end

        def count
          @mutex.synchronize do
            @looked_up += 1
            Rails.logger.info("Goodreads rebuild evidence: #{@looked_up} editions") if (@looked_up % PROGRESS_EVERY).zero?
          end
        end

        # Editions of the rows that name a derived book (merged-away legacy
        # ids included), without evidence, by id.
        def edition_ids
          legacy_ids = LegacyBookMap.build.all_legacy_ids_for(Cohort.derived.pluck(:id))
          ids = legacy_ids.each_slice(10_000).flat_map do |slice|
            ::Books::GoodreadsImportRow.where(legacy_book_id: slice).where.not(goodreads_edition_id: nil).distinct.pluck(:goodreads_edition_id)
          end.uniq.sort
          done = ::Books::RebuildEditionEvidence.pluck(:goodreads_book_id, :signature).to_set
          ids = ids.each_slice(10_000).flat_map do |slice|
            ::Books::GoodreadsEdition.where(id: slice).pluck(:id, :goodreads_book_id, :signature)
              .reject { |_, goodreads_id, signature| done.include?([goodreads_id, signature]) }.map(&:first)
          end.sort
          @limit ? ids.first(@limit) : ids
        end

        def result(stopped:, error:)
          Result.new(success?: !stopped, data: {looked_up: @looked_up, stopped: stopped, error: error}, errors: [error].compact)
        end
      end
    end
  end
end
