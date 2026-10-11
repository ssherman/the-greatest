# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      # Quarter-star spec §5.4. The legacy site's Goodreads importer did
      # "3.75".to_i, so a legacy review copied here says 3 where the reader's
      # uploaded CSV says 3.75. This puts the CSV value back, and only when all
      # four hold, so a rating the reader changed is never touched:
      #
      # 1. the row is from a legacy_replay import (the candidate query; a
      #    member's own import is never a source)
      # 2. the review's id is below the reserved ceiling (legacy origin)
      # 3. the CSV rating is fractional
      # 4. the stored rating equals the CSV rating rounded down, which is what
      #    to_i produced
      #
      # Where a reader uploaded the same book more than once, the latest upload
      # is their latest rating. Idempotent, and it repeats: the weekly
      # data_migration:sync overwrites legacy-origin reviews with legacy's
      # integer, so every replay pass runs this again. It runs after the final
      # apply because merges have by then settled which book a review sits on.
      # update_all keeps timestamps and skips the summary callback, so each
      # repaired book is recalculated once, after the repairs (also when one fails).
      class RepairTruncatedRatings
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        USER_BATCH = 500

        def self.call
          new.call
        end

        def call
          checked = 0
          repaired = 0
          repaired_book_ids = Set.new
          begin
            candidates.distinct.pluck("books_goodreads_imports.user_id").each_slice(USER_BATCH) do |user_ids|
              winners = winners_for(user_ids)
              reviews = existing_reviews(winners)
              winners.each do |(user_id, book_id), row|
                checked += 1
                review_id, stored = reviews[[user_id, book_id]]
                next unless repairable?(review_id, stored, row.rating)

                ::Review.where(id: review_id).update_all(rating: row.rating)
                repaired_book_ids << book_id
                repaired += 1
              end
            end
          ensure
            # A failure part-way must not leave the books already written with a
            # stale summary: a re-run would no longer find them repairable.
            repaired_book_ids.each { |book_id| ::Services::Reviews::SummaryRecalculator.recalculate("Books::Book", book_id) }
          end
          Result.new(success?: true, data: {checked: checked, repaired: repaired}, errors: [])
        end

        private

        # Rows that make a (user, book) worth examining: a fractional rating.
        def candidates
          rated_rows.where("books_goodreads_import_rows.rating <> TRUNC(books_goodreads_import_rows.rating)")
        end

        def rated_rows
          ::Books::GoodreadsImportRow.joins(:import, :goodreads_edition)
            .where(books_goodreads_imports: {source: ::Books::GoodreadsImport.sources.fetch("legacy_replay")})
            .where.not(books_goodreads_editions: {book_id: nil})
            .where("books_goodreads_import_rows.rating > 0")
        end

        # One row per examined (user, book), chosen among ALL the user's rated
        # replay rows for the book, not only the fractional ones: the latest
        # import, then the latest Date Read (undated last), then the lowest row
        # number. A reader who re-rated 3.25 as 3 in a newer upload has the 3.
        def winners_for(user_ids)
          examined = candidates.where(books_goodreads_imports: {user_id: user_ids}).distinct
            .pluck("books_goodreads_imports.user_id", "books_goodreads_editions.book_id").to_set
          rated_rows.where(books_goodreads_imports: {user_id: examined.map(&:first).uniq},
            books_goodreads_editions: {book_id: examined.map(&:last).uniq})
            .select("books_goodreads_import_rows.rating, books_goodreads_import_rows.date_read, " \
              "books_goodreads_import_rows.row_number, books_goodreads_imports.user_id AS user_id, " \
              "books_goodreads_editions.book_id AS book_id, " \
              "books_goodreads_imports.created_at AS import_created_at, books_goodreads_imports.id AS import_pk")
            .group_by { |row| [row.user_id, row.book_id] }
            .slice(*examined)
            .transform_values do |rows|
              rows.min_by { |row| [-row.import_created_at.to_f, -row.import_pk, -(row.date_read&.jd || 0), row.row_number] }
            end
        end

        def existing_reviews(winners)
          return {} if winners.empty?

          ::Review.where(reviewable_type: "Books::Book", user_id: winners.keys.map(&:first).uniq,
            reviewable_id: winners.keys.map(&:last).uniq)
            .pluck(:user_id, :reviewable_id, :id, :rating).to_h { |user_id, book_id, id, rating| [[user_id, book_id], [id, rating]] }
        end

        def repairable?(review_id, stored, imported)
          review_id.present? && stored.present? &&
            review_id < ::Services::BooksMigration::RESERVED_CEILINGS.fetch("reviews") &&
            !imported.frac.zero? && stored == imported.floor
        end
      end
    end
  end
end
