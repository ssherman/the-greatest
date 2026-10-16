# frozen_string_literal: true

module Services
  module Books
    module Verification
      # Spec section 2, stage 4: recorded, never acted on. The book's held
      # ISBNs and Goodreads ids that are still not verified are looked up in
      # Open Library; one that points at another work whose title disagrees
      # with ours is a foreign_work finding. Two or more distinct foreign
      # works make the book a lump suspect ("X Men" holding several volumes,
      # an omnibus holding its parts' ISBNs).
      class Signals
        MAX_SIGNAL_LOOKUPS = 20
        CONCURRENCY = 5
        TYPES = {
          "books_work_isbn13" => "isbn13",
          "books_work_isbn10" => "isbn10",
          "books_work_goodreads_id" => "goodreads"
        }.freeze
        NO_HIT_STATUSES = [400, 422].freeze

        def self.call(verification:, client:)
          new(verification, client).call
        end

        def initialize(verification, client)
          @row = verification
          @client = client
          @book = verification.book
        end

        def call
          excluded_keys # memoize before any thread starts
          held = @book.identifiers.unverified.where(identifier_type: TYPES.keys).order(:id).limit(MAX_SIGNAL_LOOKUPS).pluck(:identifier_type, :value)
          hits = lookups(held).flat_map { |(type, value), found| found.map { |hit| [type, value, hit] } }
          foreign = hits.reject { |_type, _value, hit| ours?(hit) }
          works = foreign.empty? ? {} : @client.works_batch(foreign.map { |_t, _v, hit| hit.work_key }.uniq)
          foreign = foreign.select { |_t, _v, hit| (work = works[hit.work_key]) && !Check.titles_agree?(@book, work) }

          ::ActiveRecord::Base.transaction do
            foreign.each do |type, value, hit|
              Stamp.finding(@row, :foreign_work, type, value, work_key: hit.work_key, evidence: {"title" => works[hit.work_key].title})
            end
            Counts.call(@row)
            @row.update!(stage: :done, stage_error: nil, checked_at: Time.current,
              lump_suspect: foreign.map { |_t, _v, hit| hit.work_key }.uniq.size >= 2)
          end
        end

        private

        def excluded_keys
          @excluded_keys ||= begin
            keys = @book.identifiers.where(identifier_type: :books_work_openlibrary_duplicate_id).pluck(:value)
            keys << @row.new_key if @row.new_key.present? && ::Books::Verification::SETTLED_FOR_EDITIONS.include?(@row.work_outcome)
            keys
          end
        end

        def ours?(hit) = excluded_keys.include?(hit.work_key) || Array(hit.redirected_from).intersect?(excluded_keys)

        # [[type, value], [hits]] pairs, CONCURRENCY lookups at a time. The
        # threads touch no database connection.
        def lookups(held)
          held.each_slice(CONCURRENCY).flat_map do |slice|
            threads = slice.map do |type, value|
              Thread.new { [[type, value], hits_for(TYPES.fetch(type), value)] }
            end
            threads.map(&:value)
          end
        end

        def hits_for(type, value)
          @client.identifier(type, value)
        rescue ::Books::OpenLibrary::Exceptions::ClientError => e
          raise unless e.is_a?(::Books::OpenLibrary::Exceptions::NotFoundError) || NO_HIT_STATUSES.include?(e.status_code)

          []
        end
      end
    end
  end
end
