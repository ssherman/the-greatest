# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReimport
      module Apply
        # Applies a reimport_mixed verdict (re-import spec 4.1, 8 call 1): deletes a mixed book once it is empty.
        # A verdict marked kept (a reader's row matched this very book) deletes nothing.
        # The only step that deletes a book, so it re-checks everything against the database now and deletes
        # nothing that still holds a reader's entry.
        #
        # "Empty" means no review, and no list item except the originals of a copy: a copy leaves the user's
        # item on this book on purpose, and an applied reimport_row copy verdict says the user's entries were
        # already written elsewhere. Those originals are destroyed here, recorded first in the payload
        # (`deleted`). A user with a copy or move still waiting to be applied keeps the book alive, and so does
        # a guess still waiting to be applied whose item is still here.
        #
        # The book, its editions and identifiers go; the archive on the verdict (MixedBooks.archive) is how
        # it is put back by hand. The redirect to the most-read book is recorded after the commit.
        class Mixed
          def self.call(verdict:)
            return Entries.noop("already applied") if verdict.applied_at.present?
            return Entries.noop("verdict is not approved and current") unless verdict.approved? && verdict.superseded_at.nil?

            book = ::Books::Book.find_by(id: verdict.payload["book_id"])
            return gone(verdict) unless book

            # Some reader's row kept this book (DecideGuesses): it holds real readers and stays, with no redirect.
            return keep(verdict, book) if verdict.payload["kept"]

            # DecideGuesses writes the redirect once every row of the book is decided. A book that has rows but no
            # redirect yet would be deleted with no address pointing anywhere.
            if verdict.payload["redirect_to_book_id"].blank? && Array(verdict.payload["row_keys"]).any?
              return Entries.noop("waiting for redirect")
            end

            reason = nil
            kept = false
            ::ApplicationRecord.transaction do
              book.lock!
              # Everything is read again from the database under the lock: DecideGuesses may have marked the verdict
              # kept since it was loaded, and a reader's row or match may now head here.
              verdict.reload
              if verdict.payload["kept"]
                kept = true
                raise ActiveRecord::Rollback
              end
              items = copy_originals(book)
              reason = blocker(book, items)
              raise ActiveRecord::Rollback if reason

              verdict.update_columns(payload: verdict.payload.merge("deleted" => items.map { |item| attributes(item) },
                "deleted_images" => image_records(book), "redirect_written" => false))
              items.each(&:destroy!)
              keep_image_files(book)
              book.reload.destroy!
            end
            return keep(verdict, book) if kept
            return Entries.noop(reason) if reason

            redirect_to = redirect_target(verdict, book.id)

            write_redirect(verdict, book.id, redirect_to)
            Entries.applied
          end

          # A kept book stays, but what the delete path would have removed still goes: the originals of users whose
          # rows were copied away from it, except the items a row that heads to this book accounts for. Recorded in
          # the payload first, like a delete. Waits while a copy or move from this book is still unapplied.
          def self.keep(verdict, book)
            result = nil
            ::ApplicationRecord.transaction do
              book.lock!
              verdict.reload
              originals = copy_originals(book)
              if pending_row?(book, originals)
                result = Entries.noop("kept: a copy or move is not applied yet")
                raise ActiveRecord::Rollback
              end

              explained = explained_item_ids(book)
              stale = originals.reject { |item| explained.include?(item.id) }
              if stale.any?
                verdict.update_columns(payload: verdict.payload.merge("deleted" => stale.map { |item| attributes(item) }))
                stale.each(&:destroy!)
              end
              result = Entries.noop("kept: readers matched this book", final: true)
            end
            result
          end

          # Items on the book that an applied row heading to it wrote or found: the in-place rows' own record, and
          # whatever a move or add into the book put there.
          def self.explained_item_ids(book)
            ::Books::RepairVerdict.reimport_row.current.approved.where.not(applied_at: nil)
              .where("payload->>'to_book_id' = ?", book.id.to_s).flat_map do |row|
              Array(row.payload["explained_item_ids"]) + Array(row.payload.dig("moved", "list_item_ids_after"))
            end.to_set
          end

          # The run died between the delete and the redirect: this verdict recorded redirect_written false, so the
          # redirect is still owed. A book some other merge removed has no such key, and that merger's redirect stands.
          def self.gone(verdict)
            book_id = verdict.payload["book_id"]
            if verdict.payload["redirect_written"] == false
              write_redirect(verdict, book_id, redirect_target(verdict, book_id))
            end
            Entries.noop("book #{book_id} no longer exists", final: true)
          end

          def self.write_redirect(verdict, book_id, to_id)
            return unless to_id

            ::Services::BooksMigration::RedirectRecorder.merged(item_type: "Books::Book", from_id: book_id, to_id: to_id)
            verdict.update_columns(payload: verdict.payload.merge("redirect_written" => true))
          end

          # The most-read book, followed through merges. Not the book itself.
          def self.redirect_target(verdict, book_id)
            id = verdict.payload["redirect_to_book_id"]
            target = id && GoodreadsReplay::Apply::MergedBook.call(id)
            target&.id unless target&.id == book_id
          end

          # Image has_one_attached :file purges its blob when the image is destroyed, which destroying the book does.
          # Detaching first drops only the attachment row; the blob and its stored file stay, named in the archive
          # (MixedBooks.image_records), so the deletion can be reversed by hand.
          # Every image on the book and its editions, with its stored file's identity, written into the verdict at delete
          # time so images attached after the archive are covered too.
          def self.image_records(book)
            MixedBooks.image_records(book) + book.editions.order(:id).flat_map { |edition| MixedBooks.image_records(edition) }
          end

          def self.keep_image_files(book)
            ::Image.where(parent: [book, *book.editions]).find_each { |image| image.file.detach }
          end

          # Items of users who have an applied copy verdict from this book; they are the only items that may go.
          def self.copy_originals(book)
            users = ::Books::RepairVerdict.reimport_row.where.not(applied_at: nil)
              .where("payload->>'from_book_id' = ? AND payload->>'action' = 'copy'", book.id.to_s)
              .pluck(Arel.sql("(payload->>'user_id')::bigint"))
            return [] if users.empty?

            ::UserListItem.joins(:user_list).includes(:user_list)
              .where(listable_type: "Books::Book", listable_id: book.id, user_lists: {user_id: users}).order(:id).to_a
          end

          # Why the book must stay, or nil when it holds nothing but the copy originals.
          def self.blocker(book, originals)
            return "not empty: reviews remain" if ::Review.exists?(reviewable_type: "Books::Book", reviewable_id: book.id)

            return "not empty: a reader's row or match points to this book" if MixedBooks.headed_to?(book.id)

            others = ::UserListItem.where(listable_type: "Books::Book", listable_id: book.id).where.not(id: originals.map(&:id))
            return "not empty: list items remain" if others.exists?
            return "not empty: a guess is not applied yet" if pending_guess?(book)

            "not empty: a copy or move is not applied yet" if pending_row?(book, originals)
          end

          # A guess whose item has already left the book is moot; one still here is covered by the item check.
          def self.pending_guess?(book)
            ::Books::RepairVerdict.reimport_guess.approved.current.unapplied
              .where("payload->>'from_book_id' = ?", book.id.to_s).any? do |guess|
              payload = guess.payload
              if payload["item_type"] == "Review"
                ::Review.exists?(id: payload["item_id"], reviewable_type: "Books::Book", reviewable_id: book.id)
              else
                ::UserListItem.exists?(id: payload["item_id"], listable_type: "Books::Book", listable_id: book.id)
              end
            end
          end

          def self.pending_row?(book, originals)
            return false if originals.empty?

            users = originals.map { |item| item.user_list.user_id }.uniq
            ::Books::RepairVerdict.reimport_row.approved.current.unapplied
              .where("payload->>'from_book_id' = ? AND payload->>'action' IN ('copy', 'move') AND COALESCE(payload->>'superseded_by', '') = ''", book.id.to_s)
              .where("(payload->>'user_id')::bigint IN (?)", users).exists?
          end

          def self.attributes(item) = Entries.item_attributes(item).merge("user_id" => item.user_list.user_id)

          private_class_method :gone, :write_redirect, :redirect_target, :copy_originals, :blocker, :keep, :explained_item_ids, :image_records, :keep_image_files, :pending_guess?, :pending_row?, :attributes
        end
      end
    end
  end
end
