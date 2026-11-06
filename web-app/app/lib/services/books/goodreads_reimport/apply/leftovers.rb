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
          def stale(book, items)
            memo = {}
            items.group_by { |item| item.user_list.user_id }.flat_map do |user_id, user_items|
              heading = rows_of(user_id).select { |row| !row.rejected? && resolve(row.payload["to_book_id"], memo) == book.id }
              explained = heading.flat_map { |row| explained_by(row, user_id, book) }.to_set
              user_items.reject do |item|
                explained.include?(item.id) || (heading.any? && [:favorites, :custom].include?(item.user_list.try(:list_type)&.to_sym))
              end
            end.sort_by(&:id)
          end

          # Removes the stale items of one reader on a book their rows have settled, recording them on the verdict
          # first. The verdict being applied right now is marked applied here, inside the reader's lock, so a
          # sibling applying at the same moment sees it; a raise rolls the mark back with the rest. Returns how many
          # items went. Idempotent: a second call finds nothing.
          def sweep(verdict, book, user)
            return 0 if mixed?(book) || rows_of(user.id).none? { |row| row.payload["action"] == "copy" }

            removed = 0
            user.with_lock do
              book.lock!
              verdict.update_columns(applied_at: Time.current) if verdict.applied_at.nil?
              next unless settled?(book, user)

              gone = stale(book, items_of(book, [user.id]))
              next if gone.empty?

              earlier = Array(verdict.payload["leftovers_removed"])
              verdict.update_columns(payload: verdict.payload.merge("leftovers_removed" => earlier + gone.map { |item| attributes(item) }))
              gone.each(&:destroy!)
              ::UserList.where(id: gone.map(&:user_list_id).uniq).touch_all
              removed = gone.size
            end
            removed
          end

          def attributes(item) = Entries.item_attributes(item).merge("user_id" => item.user_list.user_id)

          # The reader has an applied copy from the book, every current row of theirs touching it is approved and
          # applied, and no CSV row of theirs that touches it is still without a verdict.
          def settled?(book, user)
            memo = {}
            touching = rows_of(user.id).select { |row| [resolve(row.payload["from_book_id"], memo), resolve(row.payload["to_book_id"], memo)].include?(book.id) }
            return false unless touching.any? { |row| copy_from?(row, book, memo) && row.approved? && row.applied_at }
            return false unless touching.all? { |row| row.approved? && row.applied_at }

            keys = ::Books::RepairVerdict.reimport_row.current.where("(payload->>'user_id')::bigint = ?", user.id).pluck(:subject_key).to_set
            csv_rows(user).none? { |csv| !keys.include?("reimport:row:#{csv.import_id}:#{csv.row_number}") && touches?(csv, book, memo) }
          end

          def copy_from?(row, book, memo) = row.payload["action"] == "copy" && resolve(row.payload["from_book_id"], memo) == book.id

          # The reader's current row verdicts, superseded keeps (replaced by a newer import's row) left out.
          def rows_of(user_id)
            ::Books::RepairVerdict.reimport_row.current.where("(payload->>'user_id')::bigint = ?", user_id)
              .where("COALESCE(payload->>'superseded_by', '') = ''").to_a
          end

          def csv_rows(user)
            ::Books::GoodreadsImportRow.joins(:import).merge(::Books::GoodreadsImport.legacy_replay.complete)
              .where(books_goodreads_imports: {user_id: user.id}).to_a
          end

          # A CSV row touches the book when legacy put it there, or its edition's match (any status) names it.
          def touches?(csv, book, memo)
            return true if resolve(csv.legacy_book_id, memo) == book.id

            match = csv.goodreads_edition_id && ::Books::RepairVerdict.reimport_match.current.find_by(subject_key: "reimport:edition:#{csv.goodreads_edition_id}")
            match.present? && resolve(match.payload["book_id"] || match.payload["created_book_id"], memo) == book.id
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

          def resolve(id, memo)
            return nil if id.nil?

            memo.fetch(id) { memo[id] = GoodreadsReplay::Apply::MergedBook.call(id)&.id }
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
