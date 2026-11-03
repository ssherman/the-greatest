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
            return Entries.noop("kept: readers matched this book", final: true) if verdict.payload["kept"]

            # DecideGuesses writes the redirect once every row of the book is decided. A book that has rows but no
            # redirect yet would be deleted with no address pointing anywhere.
            if verdict.payload["redirect_to_book_id"].blank? && Array(verdict.payload["row_keys"]).any?
              return Entries.noop("waiting for redirect")
            end

            redirect_to = redirect_target(verdict, book.id)
            reason = nil
            ::ApplicationRecord.transaction do
              book.lock!
              items = copy_originals(book)
              reason = blocker(book, items)
              raise ActiveRecord::Rollback if reason

              verdict.update_columns(payload: verdict.payload.merge("deleted" => items.map { |item| attributes(item) }, "redirect_written" => false))
              items.each(&:destroy!)
              book.reload.destroy!
            end
            return Entries.noop(reason) if reason

            write_redirect(verdict, book.id, redirect_to)
            Entries.applied
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

          private_class_method :gone, :write_redirect, :redirect_target, :copy_originals, :blocker, :pending_guess?, :pending_row?, :attributes
        end
      end
    end
  end
end
