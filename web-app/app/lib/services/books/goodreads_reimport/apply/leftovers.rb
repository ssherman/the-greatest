# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReimport
      module Apply
        # What a reader keeps on a book their CSV rows have left: a copy leaves the reader's original items on the
        # from-book, so once the reader's rows touching it are all settled, the items no row heading to the book
        # says they have go. A reader's imports should point at exactly what came in through their CSV.
        # Deleting a reader's entry cannot be undone by a retry, so every doubt keeps the item.
        #
        # One rule, two callers. Apply::Mixed's keep step runs `stale` for a kept mixed book (all the readers with a
        # copy from it, recorded in the mixed verdict). Row runs `sweep` for every other book, for the one reader
        # whose row just settled, and records the items on that row's verdict (`leftovers_removed`).
        #
        # What the rows SAY explains an item, not what they recorded: every current, non-rejected row of the reader
        # whose destination (followed through merges) is the book explains the items on the lists its CSV row maps to
        # (LibraryRules.existing_lists_for), plus anything it recorded writing or moving there. Favorites and
        # hand-made lists stay while any such row exists (a copy already put the destination on them). Reviews are
        # never touched, and neither is another reader's item.
        #
        # The sweep waits (touches nothing) until EVERY current row of the reader that touches the book is approved
        # and settled, and no CSV row of the reader that touches it is still without a verdict.
        module Leftovers
          module_function

          # Readers who have an applied copy verdict from this book.
          def copy_users(book)
            ::Books::RepairVerdict.reimport_row.where.not(applied_at: nil)
              .where("payload->>'from_book_id' = ? AND payload->>'action' = 'copy'", book.id.to_s)
              .pluck(Arel.sql("(payload->>'user_id')::bigint"))
          end

          def items_of(book, user_ids)
            return [] if user_ids.empty?

            ::UserListItem.joins(:user_list).includes(:user_list)
              .where(listable_type: "Books::Book", listable_id: book.id, user_lists: {user_id: user_ids}).order(:id).to_a
          end

          # A copy or move from the book, of one of these readers, that is still to be applied.
          def pending?(book, user_ids)
            return false if user_ids.empty?

            ::Books::RepairVerdict.reimport_row.approved.current.unapplied
              .where("payload->>'from_book_id' = ? AND payload->>'action' IN ('copy', 'move') AND COALESCE(payload->>'superseded_by', '') = ''", book.id.to_s)
              .where("(payload->>'user_id')::bigint IN (?)", user_ids).exists?
          end

          # The items among `items` that go: the ones no row heading to the book explains.
          def stale(book, items, ids = book_ids(book))
            memo = {}
            items.group_by { |item| item.user_list.user_id }.flat_map do |user_id, user_items|
              heading = rows_touching(user_id, book, ids, memo).select { |row| !row.rejected? && resolve(row.payload["to_book_id"], memo) == book.id }
              explained = heading.flat_map { |row| explained_by(row, user_id, book) }.to_set
              user_items.reject do |item|
                explained.include?(item.id) || (heading.any? && [:favorites, :custom].include?(item.user_list.try(:list_type)&.to_sym))
              end
            end.sort_by(&:id)
          end

          # Removes the stale items of one reader on a book their rows have settled, recording them on the verdict
          # first. The verdict being applied right now is marked applied here, inside the reader's lock, so a
          # sibling applying at the same moment sees it; a raise rolls the mark back with the rest. Returns how many
          # items went. Idempotent: a second call finds nothing. A caller sweeping several books for one verdict
          # wraps them in one transaction (Row.sweep_leftovers), so the mark commits only with the last sweep.
          def sweep(verdict, book, user)
            return 0 unless sweepable?(book, user)

            ids = book_ids(book)

            removed = 0
            user.with_lock do
              book.lock!
              verdict.update_columns(applied_at: Time.current) if verdict.applied_at.nil?
              next unless settled?(book, user, ids)

              gone = stale(book, items_of(book, [user.id]), ids)
              next if gone.empty?

              earlier = Array(verdict.payload["leftovers_removed"])
              verdict.update_columns(payload: verdict.payload.merge("leftovers_removed" => earlier + gone.map { |item| attributes(item) }))
              purge_goal_pages(gone)
              gone.each(&:destroy!)
              ::UserList.where(id: gone.map(&:user_list_id).uniq).touch_all
              removed = gone.size
            end
            removed
          end

          # Could the sweep of this book touch this reader at all? Not a mixed book (Apply::Mixed's), and the reader
          # has a copy from it. A cheap check made before any lock.
          def sweepable?(book, user)
            !mixed?(book) && rows_touching(user.id, book, book_ids(book)).any? { |row| copy_from?(row, book, {}) }
          end

          def attributes(item) = Entries.item_attributes(item).merge("user_id" => item.user_list.user_id)

          # Removing a dated Read entry changes what the reader's public reading-goal pages show, as a move does.
          # The URLs are captured now, before the destroy, and purged once the outermost transaction commits (never
          # on a rollback).
          def purge_goal_pages(items)
            urls = items.group_by { |item| item.user_list.user_id }.flat_map do |user_id, user_items|
              user = ::User.find_by(id: user_id)
              user ? Entries.goal_urls(user, user_items) : []
            end.uniq
            return if urls.empty?

            ActiveRecord.after_all_transactions_commit { ::Books::ReadingGoals::PurgeCachedPagesJob.perform_async("books", urls) }
          end

          # The reader has an applied copy from the book, every current row of theirs touching it is approved and
          # applied, no CSV row of theirs that touches it is still without a verdict, and none of their rows names a
          # book that is gone without a trace.
          def settled?(book, user, ids = book_ids(book))
            memo = {}
            touching = rows_touching(user.id, book, ids, memo)
            return false unless touching.any? { |row| copy_from?(row, book, memo) && row.approved? && row.applied_at }
            return false unless touching.all? { |row| row.approved? && row.applied_at }
            return false if untraceable?(user, memo)

            csv_rows_decided?(user, book, ids, memo)
          end

          # Is the copy from this book? Decided through MergedBook alone, never through a redirect: a deleted mixed
          # book's redirect points at a guess, and a copy from it is not a copy from the guessed book. This is the gate
          # that lets the sweep touch a reader at all, so it must not widen. Redirects only widen which rows touch or
          # head to the book, the side that keeps items or makes the sweep wait.
          def copy_from?(row, book, memo)
            return false unless row.payload["action"] == "copy"

            id = row.payload["from_book_id"]
            id && memo.fetch([:merged, id]) { memo[[:merged, id]] = GoodreadsReplay::Apply::MergedBook.call(id)&.id } == book.id
          end

          # Does a current, non-rejected row of the reader name a book that no longer exists and that nothing follows to
          # a live book? A merge of a book created after the migration, with no duplicate pair, leaves no verdict, no
          # pair and no redirect, so a row naming it could head here and nothing would say so. When in doubt, keep:
          # the sweep waits. One query returns only the gone ids the reader's rows name (a reader can have tens of
          # thousands of rows, so they are never loaded); `resolve` runs only for those.
          def untraceable?(user, memo)
            gone = ::Books::RepairVerdict.reimport_row.current.where.not(status: :rejected)
              .where("kind = 8 AND payload->>'user_id' = ?", user.id.to_s)
              .joins(Arel.sql("CROSS JOIN LATERAL (VALUES ((books_repair_verdicts.payload->>'from_book_id')::bigint), " \
                "((books_repair_verdicts.payload->>'to_book_id')::bigint)) AS named(book_id)"))
              .where("named.book_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM books_books WHERE books_books.id = named.book_id)")
              .distinct.pluck(Arel.sql("named.book_id"))
            gone.any? { |id| resolve(id, memo).nil? }
          end

          # Book ids that may resolve to this book: itself and the books merged into it, followed through chains. This
          # is the inverse of `resolve` (merge_books verdicts name the source and the target; a merged duplicate pair
          # names both halves; a record_redirects row names from and to), over-inclusive on purpose: every use confirms
          # through `resolve`.
          def book_ids(book)
            seen = Set[book.id]
            frontier = [book.id]
            GoodreadsReplay::Apply::MergedBook::MAX_HOPS.times do
              break if frontier.empty?

              sources = ::Books::RepairVerdict.merge_books.approved.where("kind = 1 AND payload->>'target_id' IN (?)", frontier.map(&:to_s))
                .pluck(Arel.sql("payload->>'source_id'")).map(&:to_i)
              pairs = ::DuplicateCandidate.merged.where(item_type: "Books::Book").where("item_a_id IN (:ids) OR item_b_id IN (:ids)", ids: frontier)
                .pluck(:item_a_id, :item_b_id).flatten
              redirected = ::RecordRedirect.where(item_type: "Books::Book", to_id: frontier).pluck(:from_id)
              frontier = (sources + pairs + redirected).uniq.reject { |id| seen.include?(id) }
              seen.merge(frontier)
            end
            seen.to_a
          end

          # The reader's current, non-superseded row verdicts whose from or to book is (or merged into) the book.
          # Narrowed in SQL by the reader and the candidate ids, then confirmed through `resolve`.
          def rows_touching(user_id, book, ids, memo = {})
            strings = ids.map(&:to_s)
            ::Books::RepairVerdict.reimport_row.current
              .where("kind = 8 AND payload->>'user_id' = ?", user_id.to_s)
              .where("payload->>'from_book_id' IN (:ids) OR payload->>'to_book_id' IN (:ids)", ids: strings)
              .where("COALESCE(payload->>'superseded_by', '') = ''").to_a
              .select { |row| [resolve(row.payload["from_book_id"], memo), resolve(row.payload["to_book_id"], memo)].include?(book.id) }
          end

          # Does a CSV row of the reader that touches the book still lack a verdict? Legacy put it on the book, or its
          # edition's match (any status) names it.
          def csv_rows_decided?(user, book, ids, memo)
            matches = ::Books::RepairVerdict.reimport_match.current
              .where("kind = 7 AND (payload->>'book_id' IN (:ids) OR payload->>'created_book_id' IN (:ids))", ids: ids.map(&:to_s)).to_a
              .select { |match| resolve(match.payload["book_id"] || match.payload["created_book_id"], memo) == book.id }
            editions = matches.map { |match| match.subject_key.delete_prefix("reimport:edition:").to_i }
            csv = ::Books::GoodreadsImportRow.joins(:import).merge(::Books::GoodreadsImport.legacy_replay.complete)
              .where(books_goodreads_imports: {user_id: user.id})
              .where("books_goodreads_import_rows.legacy_book_id IN (:ids) OR books_goodreads_import_rows.goodreads_edition_id IN (:editions)",
                ids: ids, editions: editions.presence || [0]).to_a
              .select { |row| resolve(row.legacy_book_id, memo) == book.id || editions.include?(row.goodreads_edition_id) }
            keys = ::Books::RepairVerdict.reimport_row.current.where(subject_key: csv.map { |row| "reimport:row:#{row.import_id}:#{row.row_number}" }).pluck(:subject_key).to_set
            csv.all? { |row| keys.include?("reimport:row:#{row.import_id}:#{row.row_number}") }
          end

          # The items on the book that this row says the reader has: those on the lists its CSV row maps to, and
          # whatever it recorded writing or moving there.
          def explained_by(row, user_id, book)
            ids = Array(row.payload["explained_item_ids"]) + Array(row.payload.dig("moved", "list_item_ids_after"))
            csv = ::Books::GoodreadsImportRow.find_by(import_id: row.payload["import_id"], row_number: row.payload["row_number"])
            user = ::User.find_by(id: user_id)
            if csv && user
              list_ids = GoodreadsImports::LibraryRules.existing_lists_for(user, csv).map(&:id)
              ids += ::UserListItem.where(user_list_id: list_ids, listable_type: "Books::Book", listable_id: book.id).pluck(:id)
            end
            ids
          end

          # The book an id names now, as MergedBook finds it, except that a gone id with no merge edge also follows its
          # record_redirects row. An admin merge of two books that were never a duplicate pair leaves only that row,
          # and without it a row naming the merged-away book would not count as heading to the book its items moved
          # to, so they would be swept. MergedBook itself does not follow redirects: a deleted mixed book's redirect
          # points at a guess (its most-read book), and moves and copies must not send readers there. Here a redirect
          # can only make more rows count as touching the book, which keeps items or makes the sweep wait.
          def resolve(id, memo)
            return nil if id.nil?

            memo.fetch(id) { memo[id] = follow(id.to_i) }
          end

          def follow(id)
            seen = Set.new
            GoodreadsReplay::Apply::MergedBook::MAX_HOPS.times do
              return nil if id.nil? || seen.include?(id)
              return id if ::Books::Book.exists?(id)

              seen << id
              id = GoodreadsReplay::Apply::MergedBook.merge_target(id) ||
                ::RecordRedirect.where(item_type: "Books::Book", from_id: id).where.not(to_id: nil).pick(:to_id)
            end
            nil
          end

          # Mixed books are Apply::Mixed's: it deletes them, or runs `stale` for them when kept.
          def mixed?(book)
            ::Books::RepairVerdict.reimport_mixed.current.approved.exists?(subject_key: "reimport:book:#{book.id}")
          end
        end
      end
    end
  end
end
