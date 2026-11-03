# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReimport
      module Apply
        # Applies a reimport_author verdict (re-import spec 4.8): sets the authors of a book the import made to the
        # ones its CSV rows credit. `after` maps each name to an existing author id, or to nil for an author to
        # create (DataImporters::Books::Author::Importer, which matches an existing author before it makes one).
        #
        # A trusted book (put on a list by hand) is never changed on the rule's say-so: its verdict waits as a
        # proposal until an admin has reviewed it (`reviewed_at`). The payload keeps what a wrong change needs:
        # `before_book_authors` (author, position, role, credit) and `created_author_ids`. The created ids are
        # written the moment the authors exist, so a failure after that does not lose them.
        class Author
          def self.call(verdict:)
            return Entries.noop("already applied") if verdict.applied_at.present?
            return Entries.noop("verdict is not approved and current") unless verdict.approved? && verdict.superseded_at.nil?

            payload = verdict.payload
            book = GoodreadsReplay::Apply::MergedBook.call(payload["book_id"])
            return Entries.noop("book #{payload["book_id"]} no longer exists", final: true) unless book
            if GoodreadsRebuild::Cohort.trusted?(book.id) && verdict.reviewed_at.blank?
              return Entries.noop("trusted book: needs an admin's approval")
            end

            names = ordered_names(payload)
            return Entries.noop("no authors to set") if names.empty?

            missing = names.filter_map { |name| payload["after"][name] }.reject { |id| ::Books::Author.exists?(id) }
            return Entries.noop("author #{missing.first} no longer exists", final: true) if missing.any?

            authors = resolve(verdict, book, names)
            return Entries.noop("authors already set", final: true) if book.book_authors.author.pluck(:author_id) == authors.map(&:id)

            ::ApplicationRecord.transaction do
              record_before(verdict, book)
              replace(book, authors)
            end
            Entries.applied(follow_ups: [:author_rankings])
          end

          # jsonb does not keep key order, so the rows' own order (row_author_names) says who is first.
          def self.ordered_names(payload)
            after = payload["after"] || {}
            (Array(payload["row_author_names"]) & after.keys) | after.keys
          end

          def self.resolve(verdict, book, names)
            created = Array(verdict.payload["created_author_ids"])
            authors = names.map do |name|
              id = verdict.payload["after"][name]
              next ::Books::Author.find(id) if id

              imported = ::DataImporters::Books::Author::Importer.call(
                name: name, work_titles: [book.title].compact_blank,
                providers: ::DataImporters::Books::Author::Importer::BOOK_STEP_PROVIDERS
              )
              author = imported.item
              raise "no author could be made for #{name.inspect}: #{imported.all_errors.join("; ")}" unless author&.persisted?

              created |= [author.id] if imported.created?
              author
            end
            verdict.update_columns(payload: verdict.payload.merge("created_author_ids" => created)) if created != Array(verdict.payload["created_author_ids"])
            authors.uniq(&:id)
          end

          def self.record_before(verdict, book)
            return if verdict.payload.key?("before_book_authors")

            before = book.book_authors.map { |ba| ba.attributes.slice("author_id", "position", "role", "credited_as") }
            verdict.update_columns(payload: verdict.payload.merge("before_book_authors" => before))
          end

          # Editors on the book stay; the author rows become exactly `authors`, in order.
          def self.replace(book, authors)
            book.book_authors.author.where.not(author_id: authors.map(&:id)).destroy_all
            authors.each_with_index do |author, index|
              link = ::Books::BookAuthor.find_or_initialize_by(book_id: book.id, author_id: author.id)
              link.update!(position: index + 1, role: :author)
            end
            book.book_authors.reset
            book.authors.reset
          end

          private_class_method :ordered_names, :resolve, :record_before, :replace
        end
      end
    end
  end
end
