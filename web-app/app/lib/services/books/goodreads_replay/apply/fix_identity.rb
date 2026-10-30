# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      module Apply
        # Applies a fix_identity verdict from the Goodreads rebuild: a derived
        # book whose legacy title and authors were a guess gets the export's
        # title, authors and identifiers instead. The book keeps its id, slug and
        # everything users hang on it; ResetBook clears the rest.
        #
        # Re-checked at apply time, not only when the verdict was decided: a
        # book that has become trusted since (a user put it on a real list) is
        # left alone. Passes after the first are no-ops once applied_at is set,
        # so data added after the fix is never wiped again.
        #
        # The reset, the new title and ResetBook's archive (saved on the verdict)
        # commit together, so a crash cannot lose the archive; the import runs
        # after, so a failed author import leaves a book with the right title and
        # no authors, and the next pass finishes it. A retry (whose reset finds
        # nothing left to archive) never overwrites the archive.
        class FixIdentity
          Result = Struct.new(:success?, :data, :errors, keyword_init: true)

          IMPORT_OPTIONS = {
            force_providers: true, providers: %i[authors query_identifiers], stamp_identifiers: true,
            enrich: false, query_identifier_source: :goodreads_import
          }.freeze

          def self.call(verdict:)
            return noop("already applied") if verdict.applied_at.present?

            book = ::Books::Book.find_by(id: verdict.payload["book_id"])
            return noop("book #{verdict.payload["book_id"]} no longer exists") unless book
            return noop("book #{book.id} is trusted") if GoodreadsRebuild::Cohort.trusted?(book.id)

            payload = verdict.payload
            ::Books::Book.transaction do
              archive = GoodreadsRebuild::ResetBook.call(book: book).data[:removed]
              save_payload(verdict, "removed" => archive) unless verdict.payload.key?("removed")
              book.update!(title: payload["title"], subtitle: payload["subtitle"], first_published_year: payload["year"])
            end

            links = linked_authors(payload)
            imported = import(book, payload, unlinked_names(payload, links))
            save_payload(verdict, "created_author_ids" => (Array(verdict.payload["created_author_ids"]) | imported.created_author_ids).sort)
            failed = imported.provider_results.find { |r| r.provider_name.to_s.end_with?("::Authors") && r.failure? }
            raise Failed, "author import failed: #{failed.errors.join("; ")}" if failed

            link_authors(book, payload, links)
            Result.new(success?: true, data: {outcome: :applied}, errors: [])
          end

          # The existing authors the rebuild judged to be the export's people (MatchAuthors), by export name.
          # One that has been merged away or deleted since is simply absent, and its name is imported.
          def self.linked_authors(payload)
            found = ::Books::Author.where(id: Hash(payload["author_links"]).values).index_by(&:id)
            Hash(payload["author_links"]).filter_map { |name, id| [name, found[id]] if found[id] }.to_h
          end

          def self.unlinked_names(payload, links)
            Array(payload["author_names"]) - links.keys
          end

          def self.import(book, payload, unlinked)
            providers = unlinked.any? ? IMPORT_OPTIONS[:providers] : IMPORT_OPTIONS[:providers] - [:authors]
            match = ::DataImporters::Match.new(outcome: :matched, record: book, confidence: :certain, decided_by: :rule,
              reason: "goodreads rebuild fix_identity", candidates: [])
            query = GoodreadsRebuild::ExportFacts.query_attributes(payload).except(:series_name, :series_number)
            ::DataImporters::Books::Book::Importer.call(**query, author_names: unlinked, match: match, **IMPORT_OPTIONS, providers: providers)
          end

          # Linked after the import, not before: the importer's author step does nothing for a book that
          # already has authors, so linking first would leave the unlinked names unimported. Every author
          # then gets its place in the export's order, imported ones filling the names that were not linked.
          def self.link_authors(book, payload, links)
            return if links.empty?

            links.each do |name, author|
              book.book_authors.find_or_create_by!(author: author)
              held = ::Services::Text::PersonNameKey.all([author.name, *Array(author.alternate_names)])
              author.update!(alternate_names: Array(author.alternate_names) + [name]) unless held.include?(::Services::Text::PersonNameKey.call(name))
            end
            imported = book.book_authors.reload.reject { |row| links.values.any? { |author| author.id == row.author_id } }.sort_by { |row| [row.position.to_i, row.id] }
            order = Array(payload["author_names"]).filter_map { |name| links[name]&.id || imported.shift&.author_id }.uniq
            order.each_with_index { |author_id, index| book.book_authors.find_by!(author_id: author_id).update!(position: index + 1) }
            book.authors.reset
          end

          def self.save_payload(verdict, additions)
            verdict.update_columns(payload: verdict.payload.merge(additions))
          end

          def self.noop(reason)
            Result.new(success?: true, data: {outcome: :noop, reason: reason}, errors: [])
          end

          private_class_method :linked_authors, :unlinked_names, :import, :link_authors, :save_payload, :noop
        end
      end
    end
  end
end
