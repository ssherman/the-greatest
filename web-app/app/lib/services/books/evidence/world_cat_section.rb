# frozen_string_literal: true

module Services
  module Books
    module Evidence
      # The WorldCat part of a book's evidence row. A verified ISBN is trusted; an
      # unverified one is accepted only when its full record agrees with the book on
      # title, creator and year, so a wrong ISBN cannot feed another book's genres in.
      # Client errors other than the cases below propagate to Gather.
      class WorldCatSection
        ISBN_TYPES = %w[books_work_isbn13 books_work_isbn10].freeze
        MAX_ISBNS = 50
        MAX_IDENTITY_CHECKS = 5
        MIN_FULL_RECORDS = 3
        MAX_EXTRA_FULL_RECORDS = 3
        MAX_SUBJECTS = 40
        MAX_SUMMARY = 1_500

        def self.call(book:, client: ::Books::WorldCat::Client.new, map: nil)
          new(book, client, map).call
        end

        def initialize(book, client, map)
          @book = book
          @client = client
          @map = map
          @full = {}
        end

        def call
          verified = verified_isbns
          isbns = held_isbns(verified)
          return if isbns.empty?

          @map ||= ::Books::WorldCat::GenreMap.load
          found = @client.lookup(isbns).select { |_isbn, records| records.present? }
          trusted, unverified = found.keys.partition { |isbn| verified.include?(isbn) }
          accepted = trusted.dup
          rejected = []
          ranked = unverified.sort_by.with_index { |isbn, index| [-found[isbn].size, index] }
          checked = ranked.first(MAX_IDENTITY_CHECKS)
          load_full_records(checked.map { |isbn| found[isbn].first.oclc })
          checked.each do |isbn|
            (identity_agrees?(found[isbn].first) ? accepted : rejected) << isbn
          end
          unchecked = ranked.drop(MAX_IDENTITY_CHECKS)

          records = Services::Books::WorldCat::MergedDuplicates.reject(accepted.flat_map { |isbn| found[isbn] }.uniq(&:oclc))
          return if records.empty?

          build(records, accepted, rejected, unchecked)
        end

        private

        def isbn13s(identifiers)
          identifiers.filter_map { |identifier| ::Books::Isbn.normalize(identifier.value)&.isbn13 }
        end

        def verified_isbns
          isbn13s(@book.identifiers.verified.where(identifier_type: ISBN_TYPES)).to_set
        end

        # Verified first, then in id order; invalid check digits never leave here.
        def held_isbns(verified)
          all = isbn13s(@book.identifiers.where(identifier_type: ISBN_TYPES).order(:id)).uniq
          (all.select { |isbn| verified.include?(isbn) } + all.reject { |isbn| verified.include?(isbn) }).first(MAX_ISBNS)
        end

        # A missing (nil) or timed-out full record is no evidence the ISBN is this book's.
        def identity_agrees?(slim)
          full = @full[slim.oclc]
          full.present? && Services::Books::Verification::WorldCatCheck.agrees?(@book, full)
        end

        # One batch for the numbers not fetched yet. A number the service has no record for,
        # and every number in a batch that timed out (a 504 now covers the whole batch), is cached as nil.
        def load_full_records(oclcs)
          missing = oclcs.uniq - @full.keys
          return if missing.empty?

          fetched = begin
            @client.records_by_oclc(missing)
          rescue ::Books::WorldCat::Exceptions::ServerError => error
            raise unless error.status_code == 504

            {}
          end
          missing.each { |oclc| @full[oclc] = fetched[oclc] }
        end

        def build(records, accepted, rejected, unchecked)
          mapped = records.flat_map do |record|
            record.genre.present? ? @map.targets_for(record.genre).map { |target| "#{target.kind}:#{target.name}" } : []
          end
          subjects = records.flat_map(&:subjects).tally.sort_by { |heading, count| [-count, heading] }.first(MAX_SUBJECTS).to_h
          fulls = full_records(records)
          english = fulls.select { |full| full.cataloging_language.nil? || full.cataloging_language == "eng" }

          {
            "records" => records.size,
            "isbns_accepted" => accepted,
            "isbns_rejected" => rejected,
            "isbns_unchecked" => unchecked,
            "genre_terms" => records.filter_map(&:genre).tally,
            "mapped_genres" => mapped.tally,
            "subjects" => subjects,
            "summary" => english.filter_map(&:summary).select(&:present?).max_by(&:length)&.slice(0, MAX_SUMMARY),
            "publication_places" => fulls.filter_map(&:publication_place).select(&:present?).uniq,
            "earliest_year" => records.filter_map { |record| record.year.to_i if record.year.to_i.positive? }.min,
            "cataloging_languages" => records.filter_map(&:cataloging_language).tally
          }
        end

        # Full records of accepted editions (verified ISBNs are trusted, so theirs count
        # too). Only the summary is limited to English cataloguing: a summary in another
        # language says nothing useful about an English book, but a place is a place.
        def full_records(records)
          oclcs = records.map(&:oclc)
          if @full.values_at(*oclcs).compact.size < MIN_FULL_RECORDS
            load_full_records((oclcs - @full.keys).first(MAX_EXTRA_FULL_RECORDS))
          end
          @full.values_at(*oclcs).compact
        end
      end
    end
  end
end
