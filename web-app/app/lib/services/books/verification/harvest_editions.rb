# frozen_string_literal: true

module Services
  module Books
    module Verification
      # Spec section 2, stage 2: the settled work's editions. Agreeing ones
      # give trusted work-level identifiers (Stamp); the rest are kept as
      # candidates for a later AI check. Network first, then one transaction
      # that ends by moving the row to worldcat.
      class HarvestEditions
        FIELDS = {
          isbn13: "books_work_isbn13",
          isbn10: "books_work_isbn10",
          oclc: "books_work_oclc_id",
          goodreads: "books_work_goodreads_id"
        }.freeze
        DIGITS = /\A\d+\z/

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
          work = @client.works_batch([key])[key]
          editions = @client.editions(key)

          ::ActiveRecord::Base.transaction do
            editions.each do |edition|
              if EditionCheck.agrees?(@book, work, edition)
                stamp_values(edition)
              else
                keep_candidate(edition, key)
              end
            end
            Counts.call(@row)
            @row.update!(stage: :worldcat, stage_error: nil)
          end
        end

        private

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
