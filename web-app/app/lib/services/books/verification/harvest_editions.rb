# frozen_string_literal: true

module Services
  module Books
    module Verification
      # Spec section 2, stage 2: the settled work's editions. Agreeing ones
      # give trusted work-level identifiers (Stamp); the rest are kept as
      # candidates for a later AI check. Network first, then one transaction
      # that ends by moving the row to worldcat.
      #
      # Open Library often keeps one book as several works, and the settled one
      # can be a translation's ("Alguien voló sobre el nido del cuco" for One
      # Flew Over the Cuckoo's Nest). So the book's duplicate work keys that
      # Open Library gave us are harvested the same way, under a stricter gate
      # than Check's: the duplicate's full title must be our own title (a
      # leading article aside) and an author must agree. Check alone would let
      # in "The Lord of the Rings: The Two Towers" for "The Lord of the Rings",
      # and EditionCheck trusts every edition titled like the work it is given.
      # A key another book holds as its work key is that book's, not ours.
      class HarvestEditions
        FIELDS = {
          isbn13: "books_work_isbn13",
          isbn10: "books_work_isbn10",
          oclc: "books_work_oclc_id",
          goodreads: "books_work_goodreads_id"
        }.freeze
        DIGITS = /\A\d+\z/
        MAX_DUPLICATE_WORKS = 5

        def self.call(verification:, client:)
          new(verification, client).call
        end

        def initialize(verification, client)
          @row = verification
          @client = client
          @book = verification.book
        end

        def call
          key = @row.new_key
          duplicates = duplicate_keys - [key]
          works = @client.works_batch([key] + duplicates)
          harvested = [[key, works[key], @client.editions(key)]]
          same_book_works(duplicates, works, key).each do |work|
            harvested << [work.key, work, duplicate_editions(work.key)]
          end

          ::ActiveRecord::Base.transaction do
            harvested.each do |work_key, work, editions|
              editions.each do |edition|
                if EditionCheck.agrees?(@book, work, edition)
                  stamp_values(edition)
                else
                  keep_candidate(edition, work_key)
                end
              end
            end
            Counts.call(@row)
            @row.update!(stage: :worldcat, stage_error: nil)
          end
        end

        private

        def duplicate_keys
          @book.identifiers.where(identifier_type: :books_work_openlibrary_duplicate_id, source: :open_library)
            .order(:id).limit(MAX_DUPLICATE_WORKS).pluck(:value)
        end

        # The live works behind the duplicate keys, once each (two keys can
        # redirect to one work, or to the settled one), that pass the gate.
        def same_book_works(duplicates, works, settled_key)
          held_elsewhere = ::Identifier.where(identifiable_type: "Books::Book", identifier_type: :books_work_openlibrary_id)
            .where.not(identifiable_id: @book.id).where(value: duplicates + duplicates.filter_map { |d| works[d]&.key })
            .pluck(:value).to_set
          seen = Set[settled_key]
          duplicates.filter_map do |duplicate|
            work = works[duplicate]
            next if work.nil? || seen.include?(work.key) || held_elsewhere.include?(duplicate) || held_elsewhere.include?(work.key)

            seen << work.key
            work if same_title?(work) && Check.verified?(@book, work, @client)
          end
        end

        LEADING_ARTICLE = /\A(the|a|an) /

        # The work's full title (subtitle included) is our own title, a leading
        # article aside. Alternate titles do not count: legacy data gives some
        # volumes their series' name.
        def same_title?(work)
          theirs = Check.their_titles(work).first
          ours = Check.normalize(@book.title)
          theirs.present? && ours.present? && theirs.sub(LEADING_ARTICLE, "") == ours.sub(LEADING_ARTICLE, "")
        end

        # A duplicate Open Library no longer has is skipped; the settled work's
        # own 404 still stops the book (Run treats it as book-specific).
        def duplicate_editions(work_key)
          @client.editions(work_key)
        rescue ::Books::OpenLibrary::Exceptions::NotFoundError
          []
        end

        def stamp_values(edition)
          evidence = {"edition_key" => edition.key, "title" => [edition.title, edition.subtitle].compact.join(": ")}
          FIELDS.each do |field, type|
            values(edition, field).each do |value|
              Stamp.call(verification: @row, type: type, value: value, source: :open_library, evidence: evidence)
            end
          end
        end

        def values(edition, field)
          raw = Array(edition.public_send(field))
          case field
          when :isbn13 then raw.filter_map { |value| ::Books::Isbn.normalize(value)&.isbn13 }
          when :isbn10 then raw.filter_map { |value| ::Books::Isbn.normalize(value)&.isbn10 }
          else raw.map { |value| value.to_s.strip }.grep(DIGITS)
          end.uniq
        end

        def keep_candidate(edition, work_key)
          candidate = ::Books::EditionCandidate.find_or_initialize_by(book_id: @book.id, edition_key: edition.key)
          candidate.update!(
            work_key: work_key, title: edition.title, subtitle: edition.subtitle, language_code: edition.language_code,
            publish_year: edition.publish_year,
            identifiers: FIELDS.keys.to_h { |field| [field.to_s, Array(edition.public_send(field))] }
          )
        end
      end
    end
  end
end
