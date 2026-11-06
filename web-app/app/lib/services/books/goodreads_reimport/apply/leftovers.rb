# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReimport
      module Apply
        # What a reader keeps on a book their CSV rows have left: a copy leaves the reader's original items on the
        # from-book, so once every copy from it has applied, the items no row heading to the book accounts for go.
        # A reader's imports should point at exactly what came in through their CSV.
        #
        # One rule, two callers. Apply::Mixed's keep step runs it for a kept mixed book (all the readers with a
        # copy from it, recorded in the mixed verdict). Row runs `sweep` for every other book, for the one reader
        # whose copy just applied, and records the items on that row's verdict (`leftovers_removed`).
        #
        # An item stays when a row heading to the book wrote or found it (`explained_item_ids`, or what a move or add
        # put there), and Favorites and hand-made lists stay while any row of that reader heads to the book (a copy
        # already put the destination on them). Reviews are never touched. Another reader's items are never touched.
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

          # A copy or move from the book, of one of these readers, that is still to be applied (`except`: the verdict
          # being applied right now, which the orchestrator marks applied after it returns).
          def pending?(book, user_ids, except: nil)
            return false if user_ids.empty?

            scope = ::Books::RepairVerdict.reimport_row.approved.current.unapplied
              .where("payload->>'from_book_id' = ? AND payload->>'action' IN ('copy', 'move') AND COALESCE(payload->>'superseded_by', '') = ''", book.id.to_s)
              .where("(payload->>'user_id')::bigint IN (?)", user_ids)
            scope = scope.where.not(id: except.id) if except
            scope.exists?
          end

          # The items among `items` that go. `including`: a row verdict not yet marked applied whose record counts.
          def stale(book, items, including: nil)
            return [] if items.empty?

            explained = explained_item_ids(book, including)
            heading = users_heading_to(book, items.map { |item| item.user_list.user_id }.uniq, including)
            items.reject do |item|
              explained.include?(item.id) ||
                ([:favorites, :custom].include?(item.user_list.try(:list_type)&.to_sym) && heading.include?(item.user_list.user_id))
            end
          end

          # Removes the stale items of one reader on a book their last copy has left, recording them on the verdict
          # first. Returns how many went. Idempotent: a second call finds nothing.
          def sweep(verdict, book, user)
            return 0 if mixed?(book)

            removed = 0
            ::ApplicationRecord.transaction do
              book.lock!
              next if pending?(book, [user.id], except: verdict)

              gone = stale(book, items_of(book, [user.id]), including: verdict)
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

          # Items on the book that an applied row heading to it wrote or found: the in-place rows' own record, and
          # whatever a move or add into the book put there.
          def explained_item_ids(book, including = nil)
            rows = heading_rows(book).where.not(applied_at: nil).to_a
            rows << including if including
            rows.flat_map do |row|
              Array(row.payload["explained_item_ids"]) + Array(row.payload.dig("moved", "list_item_ids_after"))
            end.to_set
          end

          def users_heading_to(book, user_ids, including = nil)
            ids = heading_rows(book).where("(payload->>'user_id')::bigint IN (?)", user_ids).pluck(Arel.sql("(payload->>'user_id')::bigint"))
            ids << including.payload["user_id"] if including && including.payload["to_book_id"].to_s == book.id.to_s
            ids.to_set
          end

          def heading_rows(book)
            ::Books::RepairVerdict.reimport_row.current.approved
              .where("payload->>'to_book_id' = ? AND COALESCE(payload->>'superseded_by', '') = ''", book.id.to_s)
          end

          # Mixed books are Apply::Mixed's: it deletes them, or runs this for them when kept.
          def mixed?(book)
            ::Books::RepairVerdict.reimport_mixed.current.approved.exists?(subject_key: "reimport:book:#{book.id}")
          end
        end
      end
    end
  end
end
