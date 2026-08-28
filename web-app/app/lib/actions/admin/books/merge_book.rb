module Actions
  module Admin
    module Books
      # Every Books:: constant in here is root-anchored. Inside
      # Actions::Admin::Books, a bare `Books::Book` resolves to
      # Actions::Admin::Books::Book and raises a confusing NameError.
      class MergeBook < Actions::Admin::BaseAction
        def self.name
          "Merge Another Book Into This One"
        end

        def self.message
          "Search for a duplicate book to merge into the current book. The source book will be permanently deleted after merging."
        end

        def self.confirm_button_label
          "Merge Book"
        end

        def self.visible?(context = {})
          context[:view] == :show
        end

        # The ONLY place the merge permission gate is enforced is the controller's
        # `authorize @record, :destroy? if action_class.destructive?`. Omitting this
        # override leaves that gate silently inert and lets a domain editor delete a
        # record by merging it. Guarded by test/lint/merge_actions_destructive_test.rb.
        def self.destructive?
          true
        end

        def call
          return error("This action can only be performed on a single book.") if models.count != 1

          target_book = models.first

          source_book_id = fields[:source_book_id] || fields["source_book_id"]
          confirm_merge = fields[:confirm_merge] || fields["confirm_merge"]

          unless source_book_id.present?
            return error("Please select a book to merge.")
          end

          unless confirm_merge == "1" || confirm_merge == true
            return error("Please confirm you understand this action cannot be undone.")
          end

          source_book = ::Books::Book.find_by(id: source_book_id)

          unless source_book
            return error("Book with ID #{source_book_id} not found.")
          end

          if source_book.id == target_book.id
            return error("Cannot merge a book with itself. Please select a different book.")
          end

          source_title = source_book.title
          source_id = source_book.id

          merger = ::Books::Book::Merger.new(source: source_book, target: target_book)
          result = merger.call

          if result.success?
            succeed_or_warn(merger, source_title, source_id, target_book)
          else
            error "Failed to merge books: #{result.errors.join(", ")}"
          end
        end

        private

        def succeed_or_warn(merger, source_title, source_id, target_book)
          message = "Successfully merged '#{source_title}' (ID: #{source_id}) into " \
            "'#{target_book.title}'. The source book has been deleted."

          note = not_transferred_note(merger)
          message += " #{note}" if note.present?

          if merger.stats[:post_commit_error].present?
            warn "#{message} Note: search reindexing, ranking recalculation and the " \
              "generated favorites rebuild could not be scheduled " \
              "(#{merger.stats[:post_commit_error]}); they will need to be re-run."
          else
            succeed message
          end
        end

        # The authors/credits gate declines to transfer onto a book that already has
        # its own, to avoid two rows for the same person on the survivor. Say so, or
        # the admin has no way to know the duplicate's authors were left behind.
        def not_transferred_note(merger)
          parts = []
          authors = merger.stats[:book_authors_not_transferred].to_i
          credits = merger.stats[:credits_not_transferred].to_i

          parts << "#{authors} author#{"s" unless authors == 1}" if authors.positive?
          parts << "#{credits} credit#{"s" unless credits == 1}" if credits.positive?
          return "" if parts.empty?

          "The duplicate's #{parts.join(" and ")} did not transfer, because this book " \
            "already has its own."
        end
      end
    end
  end
end
