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
          held = @book.identifiers.unverified.where(identifier_type: TYPES.keys).order(:id).pluck(:identifier_type, :value)
            .select { |type, value| lookupable?(type, value) }.first(MAX_SIGNAL_LOOKUPS)
          hits = lookups(held).flat_map { |(type, value), found| found.map { |hit| [type, value, hit] } }
          foreign = hits.reject { |_type, _value, hit| ours?(hit) }
          works = foreign.empty? ? {} : @client.works_batch(foreign.map { |_t, _v, hit| hit.work_key }.uniq)
          foreign = foreign.select { |_t, _v, hit| (work = works[hit.work_key]) && !known_translation?(work) && !titles_agree?(work) }

          # One finding per identifier, listing every foreign work it hits.
          by_identifier = foreign.group_by { |type, value, _hit| [type, value] }.transform_values do |rows|
            rows.map { |_t, _v, hit| hit.work_key }.uniq.sort.map { |key| {"key" => key, "title" => works[key].title} }
          end

          ::ActiveRecord::Base.transaction do
            # Stage 4 recomputes its findings completely; a re-run must not keep stale ones.
            @row.findings.foreign_work.delete_all
            by_identifier.each do |(type, value), listed|
              Stamp.finding(@row, :foreign_work, type, value, work_key: listed.first["key"], evidence: {"works" => listed})
            end
            Counts.call(@row)
            @row.update!(stage: :done, stage_error: nil, checked_at: Time.current,
              lump_suspect: by_identifier.values.flatten.map { |w| w["key"] }.uniq.size >= 2)
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

        # A title the book's own edition candidates already carry is a known
        # translation, whatever its language: Open Library keeps some as works.
        def known_translation?(work)
          theirs = Check.their_title_keys(work).first
          theirs.present? && candidate_titles.include?(theirs)
        end

        def candidate_titles
          @candidate_titles ||= ::Books::EditionCandidate.where(book_id: @book.id).pluck(:title, :subtitle).flat_map { |title, subtitle|
            [Check.title_key(title), Check.title_key([title, subtitle.presence].compact.join(": "))]
          }.compact.to_set
        end

        def titles_agree?(work) = Check.titles_agree?(@book, work)

        # Legacy data holds junk under these types ("Twelfth Night" as an
        # ISBN-13). It cannot be a hit, so it is not worth a lookup slot. A
        # slug-form Goodreads id ("32076670-ball-lightning") is valid: the
        # service reads its leading digits, as GoodreadsId does.
        def lookupable?(type, value)
          (type == "books_work_goodreads_id") ? ::Books::GoodreadsId.normalize(value).present? : ::Books::Isbn.normalize(value).present?
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
