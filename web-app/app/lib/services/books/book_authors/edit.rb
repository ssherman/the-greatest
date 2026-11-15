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
          unless ::Books::Author.exists?(author_id)
            return failure("No author #{author_id}.", :unprocessable)
          end
          return duplicate(author_id) if book.book_authors.exists?(author_id: author_id)

          attrs["position"] = next_position(book) if attrs["position"].nil?
          row = book.book_authors.build(attrs.merge("author_id" => author_id))
          save(row)
        rescue ActiveRecord::RecordNotUnique
          duplicate(author_id)
        end

        def self.update(book:, author_id:, attrs:)
          row = book.book_authors.find_by(author_id: author_id)
          return not_on_book(book, author_id) unless row

          row.assign_attributes(normalize(attrs))
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

        def self.next_position(book)
          (book.book_authors.maximum(:position) || 0) + 1
        end
        private_class_method :next_position

        def self.save(row)
          if row.save
            Result.new(success?: true, data: row, errors: [])
          else
            failure(row.errors.full_messages, :unprocessable)
          end
        rescue ArgumentError => e # an unknown role
          failure(e.message, :unprocessable)
        end
        private_class_method :save

        def self.duplicate(author_id)
          failure("Author #{author_id} is already on this book. Use update_book_author to change the role, position or credited_as.", :unprocessable)
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
