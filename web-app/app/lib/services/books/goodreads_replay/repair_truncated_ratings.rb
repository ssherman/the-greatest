# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      # Quarter-star spec §5.4. The legacy site's Goodreads importer did
      # "3.75".to_i, so a legacy review copied here says 3 where the reader's
      # uploaded CSV says 3.75. This puts the CSV value back, but only for a
      # review the creating import provably wrote, selected by provenance
      # rather than by value:
      #
      # - The stored rating equalling the CSV rating rounded down proves
      #   nothing. The legacy importer used find_or_create_by, so a review that
      #   predates the upload was left alone and can still match, and so can a
      #   reader who later set it back to 3. The step repeats after every weekly
      #   sync, so a value test alone would overwrite deliberate ratings on each
      #   pass.
      # - A replay import created the review iff its created_at falls in
      #   [started_at, started_at + RUN_BOUND] (the original run) or
      #   [finished_at - RUN_BOUND, finished_at] (the admin's "Re-execute
      #   Import" re-runs it, and a run ends at the legacy updated_at). The
      #   whole window is no proof: re-execution moves finished_at months on.
      #   Any status counts, since a failed import may have created reviews
      #   before failing. No matching import, or more than one, skips.
      # - Untouched: updated_at == created_at, which is how the legacy importer
      #   creates. Any later edit (reader, relink, anything) changes it.
      # - The value is the creating import's rows for that book rated 1 or more
      #   (the parser skipped lower ratings). If they disagree the new app may
      #   have resolved rows to books differently from legacy, so skip. Repair
      #   only if the value is fractional and the stored rating is its floor.
      #
      # Every miss fails safe by leaving the truncated value. Gaps by design:
      # runs longer than RUN_BOUND match only their nearest segment, stuck legacy
      # imports (pending) never match, and a relinked review is never repaired.
      # Idempotent: the weekly data_migration:sync overwrites legacy-origin
      # reviews with legacy's integer and keeps legacy's timestamps, so each
      # replay pass repairs again. It runs after the final apply because merges
      # have by then settled which book a review sits on. update_all keeps
      # timestamps and skips the summary callback, so each repaired book is
      # recalculated once, after the repairs (also when one fails).
      class RepairTruncatedRatings
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        USER_BATCH = 500
        # How long one legacy import run can take. Measured on the legacy
        # restore (2026-10-11): single runs p50 149 s, p99 3.8 h, max 19 h. A
        # longer run skips, which fails safe.
        RUN_BOUND = 6.hours
        Window = Struct.new(:id, :started_at, :finished_at)

        def self.call
          new.call
        end

        def call
          checked = 0
          repaired = 0
          repaired_book_ids = Set.new
          begin
            candidate_user_ids.each_slice(USER_BATCH) do |user_ids|
              pairs = candidate_pairs(user_ids)
              reviews = legacy_reviews(pairs)
              imports = imports_by_user(user_ids)
              values = rated_values(reviews, imports)
              reviews.each do |(user_id, book_id), (review_id, stored, created_at, updated_at)|
                checked += 1
                next unless updated_at == created_at

                creating = creating_import(imports[user_id], created_at)
                imported = creating && values[[creating.id, book_id]]
                next unless imported && imported.size == 1

                imported = imported.first
                next unless !imported.frac.zero? && stored == imported.floor

                ::Review.where(id: review_id).update_all(rating: imported)
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

        def candidate_user_ids
          fractional_rows.distinct.order("books_goodreads_imports.user_id").pluck("books_goodreads_imports.user_id")
        end

        # (user, book) pairs with a fractional rating in some replay import.
        def candidate_pairs(user_ids)
          fractional_rows.where(books_goodreads_imports: {user_id: user_ids}).distinct
            .pluck("books_goodreads_imports.user_id", "books_goodreads_editions.book_id")
        end

        def fractional_rows
          rated_rows.where("books_goodreads_import_rows.rating <> TRUNC(books_goodreads_import_rows.rating)")
        end

        def rated_rows
          ::Books::GoodreadsImportRow.joins(:import, :goodreads_edition)
            .where(books_goodreads_imports: {source: ::Books::GoodreadsImport.sources.fetch("legacy_replay")})
            .where.not(books_goodreads_editions: {book_id: nil})
            .where("books_goodreads_import_rows.rating > 0")
        end

        # {[user_id, book_id] => [review_id, rating, created_at, updated_at]}
        # for the legacy-origin reviews among the pairs.
        def legacy_reviews(pairs)
          wanted = pairs.to_set
          ::Review.where(reviewable_type: "Books::Book", user_id: pairs.map(&:first).uniq, reviewable_id: pairs.map(&:last).uniq)
            .where.not(rating: nil)
            .where(id: ...::Services::BooksMigration::RESERVED_CEILINGS.fetch("reviews"))
            .pluck(:user_id, :reviewable_id, :id, :rating, :created_at, :updated_at)
            .each_with_object({}) do |(user_id, book_id, id, rating, created_at, updated_at), found|
              found[[user_id, book_id]] = [id, rating, created_at, updated_at] if wanted.include?([user_id, book_id])
            end
        end

        # {user_id => [Window]}: every timed replay import, whatever its status.
        def imports_by_user(user_ids)
          ::Books::GoodreadsImport.where(source: :legacy_replay, user_id: user_ids)
            .where.not(started_at: nil).where.not(finished_at: nil)
            .pluck(:user_id, :id, :started_at, :finished_at)
            .group_by(&:first)
            .transform_values { |rows| rows.map { |_, id, started_at, finished_at| Window.new(id, started_at, finished_at) } }
        end

        # The one import whose creation segments hold the review's creation, or
        # nil when none or several do.
        def creating_import(windows, created_at)
          matches = (windows || []).select do |window|
            created_at.between?(window.started_at, window.started_at + RUN_BOUND) ||
              created_at.between?(window.finished_at - RUN_BOUND, window.finished_at)
          end
          matches.first if matches.one?
        end

        # {[import_id, book_id] => [distinct ratings]}: the ratings of the rows
        # rated 1 or more, for each import and book that can be a review's creator.
        def rated_values(reviews, imports)
          return {} if reviews.empty?

          import_ids = imports.values_at(*reviews.keys.map(&:first).uniq).compact.flatten.map(&:id)
          rated_rows.where(import_id: import_ids)
            .where(books_goodreads_editions: {book_id: reviews.keys.map(&:last).uniq})
            .where("books_goodreads_import_rows.rating >= 1")
            .distinct
            .pluck("books_goodreads_import_rows.import_id", "books_goodreads_editions.book_id", "books_goodreads_import_rows.rating")
            .group_by { |import_id, book_id, _| [import_id, book_id] }
            .transform_values { |rows| rows.map(&:last) }
        end
      end
    end
  end
end
