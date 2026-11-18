# frozen_string_literal: true

module Services
  module Books
    module PublisherIntake
      # Turns the URLs one discovery request found into listings (publisher
      # intake design §3 and §5). A URL is matched on [source, url]; what happens
      # to it depends on the row it finds and on whether this run is a baseline
      # run (new URLs are recorded but not read) or a seeding one (every URL is
      # to be read, baseline or not).
      #
      # data: {seen:, created:, changed:}, also added to the run's counts.
      class RecordDiscovery
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(run:, listings:, seed: false)
          new(run: run, listings: listings, seed: seed).call
        end

        def initialize(run:, listings:, seed:)
          @run = run
          @refs = listings.select { |ref| ref.url.present? }.uniq(&:url)
          @seed = seed
          @now = Time.current
        end

        def call
          counts = {seen: @refs.size, created: 0, changed: 0}
          existing = ::Books::PublisherListing.where(source: @run.source, url: @refs.map(&:url)).index_by(&:url)

          @refs.each do |ref|
            row = existing[ref.url]
            if row.nil?
              create(ref)
              counts[:created] += 1
            elsif touch(row, ref)
              counts[:changed] += 1
            end
          end

          add_to_run(counts)
          Result.new(success?: true, data: counts, errors: [])
        end

        private

        def create(ref)
          state = (@run.baseline && !@seed) ? :baseline : :pending
          ::Books::PublisherListing.create!(source: @run.source, url: ref.url, external_key: ref.external_key,
            signal: ref.signal, state: state, first_seen_at: @now, last_seen_at: @now)
        end

        # Returns true when a read listing was put back to pending.
        def touch(row, ref)
          row.last_seen_at = @now
          changed = row.state_read? && ref.signal.present? && ref.signal != row.signal
          if changed
            row.state = :pending
            row.signal = ref.signal
          else
            row.state = :pending if row.state_baseline? && @seed
            row.signal = ref.signal if row.signal.nil?
          end
          row.save!
          changed
        end

        def add_to_run(counts)
          @run.with_lock do
            current = @run.counts || {}
            @run.update!(counts: current.merge(
              "listings_seen" => current["listings_seen"].to_i + counts[:seen],
              "listings_new" => current["listings_new"].to_i + counts[:created],
              "listings_changed" => current["listings_changed"].to_i + counts[:changed]
            ))
          end
        end
      end
    end
  end
end
