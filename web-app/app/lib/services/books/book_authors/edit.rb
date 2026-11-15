# frozen_string_literal: true

module Services
  module Books
    module BookAuthors
      # Adds, updates and removes one author on a book. The admin page and the
      # admin API both call it, so their rules cannot drift. Rows are addressed
      # by author id. attrs keys are the strings "role", "position" and
      # "credited_as", already typed by the caller; keys not sent are left alone.
      # BookAuthor's own after_commit queues the search reindex.
      class Edit
        Result = Struct.new(:success?, :data, :errors, :code, keyword_init: true)

        def self.add(book:, author_id:, attrs: {})
          attrs = normalize(attrs)
          return bad_role if bad_role?(attrs)
          unless ::Books::Author.exists?(author_id)
            return failure("No author #{author_id}.", :unprocessable)
          end
          return duplicate(author_id) if book.book_authors.exists?(author_id: author_id)

          attrs["position"] = next_position(book) if attrs["position"].nil?
          row = book.book_authors.build(attrs.merge("author_id" => author_id))
          ::Books::BookAuthor.transaction do
            result = save(row)
            enrich_on_first_book(author_id) if result.success?
            result
          end
        rescue ActiveRecord::RecordNotUnique => e
          # Only this table's own pair index means "already on the book"; a Planner unique violation is not that.
          raise unless e.message.include?("index_books_book_authors_on_book_id_and_author_id")

          duplicate(author_id)
        end

        def self.update(book:, author_id:, attrs:)
          row = book.book_authors.find_by(author_id: author_id)
          return not_on_book(book, author_id) unless row

          attrs = normalize(attrs)
          return bad_role if bad_role?(attrs)

          row.assign_attributes(attrs)
          save(row)
        end

        def self.remove(book:, author_id:)
          row = book.book_authors.find_by(author_id: author_id)
          return not_on_book(book, author_id) unless row

          row.destroy!
          Result.new(success?: true, data: row, errors: [])
        end

        def self.normalize(attrs)
          attrs = attrs.to_h.stringify_keys
          attrs["credited_as"] = nil if attrs.key?("credited_as") && attrs["credited_as"].blank?
          attrs
        end
        private_class_method :normalize

        # An author's first book link starts its enrichment, if it has never been enriched: an author made by hand
        # has no run until it has a book to enrich from. An author that already has other books (the migrated
        # catalogue) is left alone, as is one with an earlier run (for instance an author created with a QID).
        # Planned inside the transaction, dispatched after commit, so a rollback leaves nothing. Parallel first links
        # need no lock: the index_workflow_runs_one_active unique index makes Planner reuse the active run.
        def self.enrich_on_first_book(author_id)
          return unless ::Books::BookAuthor.where(author_id: author_id).count == 1

          author = ::Books::Author.find_by(id: author_id)
          return unless author
          return if WorkflowRun.exists?(workflow: ::Workflows::Books::AuthorEnrichment.workflow, enrichable: author)

          ::Workflows::Books::AuthorEnrichment.start(author, initiated_by: "first_book_link")
        end
        private_class_method :enrich_on_first_book

        def self.next_position(book)
          # Most books hold only NULL positions, which sort last. Numbering the new
          # row 1 would put it ahead of every one of them, so it stays NULL (last by id).
          return nil if book.book_authors.where(position: nil).exists?

          (book.book_authors.maximum(:position) || 0) + 1
        end
        private_class_method :next_position

        def self.save(row)
          if row.save
            Result.new(success?: true, data: row, errors: [])
          else
            failure(row.errors.full_messages, :unprocessable)
          end
        end
        private_class_method :save

        # The enum raises on assignment, before any validation, so check first.
        def self.bad_role?(attrs)
          attrs.key?("role") && !::Books::BookAuthor.roles.key?(attrs["role"].to_s)
        end
        private_class_method :bad_role?

        def self.bad_role
          failure("role must be one of #{::Books::BookAuthor.roles.keys.join(", ")}.", :unprocessable)
        end
        private_class_method :bad_role

        def self.duplicate(author_id)
          failure("Author #{author_id} is already on this book; edit that entry instead.", :unprocessable)
        end
        private_class_method :duplicate

        def self.not_on_book(book, author_id)
          failure("Book #{book.id} has no author #{author_id}.", :not_found)
        end
        private_class_method :not_on_book

        def self.failure(messages, code)
          Result.new(success?: false, data: nil, errors: Array(messages), code: code)
        end
        private_class_method :failure
      end
    end
  end
end
