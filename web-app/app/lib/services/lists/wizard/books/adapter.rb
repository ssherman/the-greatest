# frozen_string_literal: true

module Services
  module Lists
    module Wizard
      module Books
        # The books side of the list wizard core (books list wizard spec §1):
        # parser, finder query, finder, importer, search and display.
        class Adapter
          Result = Struct.new(:success?, :data, :errors, keyword_init: true)
          LISTABLE_TYPE = "Books::Book"

          # A row created from its own text has no Open Library work: the
          # Open Library provider is left out, so a re-resolve cannot attach one.
          TEXT_PROVIDERS = %i[authors ai_enrichment author_enrichment].freeze
          CreateFailed = Class.new(StandardError)

          def listable_type = LISTABLE_TYPE

          def listable_includes = [:authors]

          def wizard_path(name, list, **params)
            helper = [name, "admin_books_list_wizard_path"].compact.join("_")
            url_helpers.public_send(helper, list_id: list.id, **params)
          end

          def search_path = url_helpers.search_admin_books_books_path

          def lists_path = url_helpers.admin_books_lists_path

          def list_path(list) = url_helpers.admin_books_list_path(list)

          def parse(list, content: nil)
            result = ::Services::Ai::Tasks::Lists::Books::RawParserTask.new(parent: list, content: content).call
            return Result.new(success?: false, data: [], errors: [result.error.presence || "Parsing failed"]) unless result.success?

            books = Array(result.data[:books] || result.data["books"])
            rows = books.map do |book|
              book = book.to_h.transform_keys(&:to_sym)
              {
                "rank" => book[:rank],
                "title" => book[:title].to_s.strip,
                "subtitle" => book[:subtitle].to_s.strip.presence,
                "authors" => Array(book[:authors]).map { |name| name.to_s.strip }.compact_blank,
                "year" => book[:publication_year]
              }
            end
            Result.new(success?: true, data: rows.reject { |row| row["title"].empty? }, errors: [])
          end

          def signature(title, authors)
            ::Services::Lists::Wizard::Core::Signature.call(title, authors)
          end

          def row_signature(item)
            metadata = item.metadata || {}
            book = item.listable
            title = metadata["title"].presence || book&.title
            authors = Array(metadata["authors"]).presence || Array(book&.authors&.map(&:name))
            signature(title, authors)
          end

          def query_for(item)
            metadata = item.metadata || {}
            ::DataImporters::Books::Book::ImportQuery.new(
              title: metadata["title"], subtitle: metadata["subtitle"],
              author_names: Array(metadata["authors"]), year: year_of(metadata)
            )
          end

          def finder
            ::DataImporters::Books::Book::Finder.new
          end

          # The Open Library keys a later Import re-check needs (spec §3): the
          # chosen work, the accepted key, its duplicates and both redirect-
          # source lists.
          def recheck_keys(match)
            keys = []
            external = match.external
            keys << external.external_key if external&.external_source == :open_library
            resolution = match.external_resolution
            if resolution
              keys << resolution.decision.key if resolution.accept?
              keys.concat(Array(resolution.decision.duplicates), Array(resolution.decision.duplicate_redirect_sources))
              keys.concat(Array(resolution.accepted&.redirect_sources))
            end
            keys.compact_blank.uniq
          end

          def find_record(id)
            ::Books::Book.find_by(id: id)
          end

          def row_display(item)
            metadata = item.metadata || {}
            {
              title: metadata["title"].presence || item.listable&.title,
              subtitle: metadata["subtitle"],
              authors: Array(metadata["authors"]).presence || Array(item.listable&.authors&.map(&:name)),
              year: metadata["year"]
            }
          end

          def record_display(book)
            {title: book.title, authors: book.authors.map(&:name), year: book.first_published_year}
          end

          # Spec §6: the Import re-check. A chosen work: a book holding it or any
          # key saved at Match. A text row: a book with the same normalized title
          # and an agreeing author, created after the row's Match.
          def recheck(item)
            state = ::Services::Lists::Wizard::Core::RowState.new(item)
            return book_holding(([state.ol_work_key] + state.ol_keys).compact_blank.uniq) if state.ol_work_key

            book_created_from_text_since_match(item, state)
          end

          # A normal book (provisional: false, enrich: true) with the row as the
          # subject and the match rebuilt from the row's decision, so the finder
          # does not run again. Rolled back when it ends up with no author.
          def create(item, importer: ::DataImporters::Books::Book::Importer)
            state = ::Services::Lists::Wizard::Core::RowState.new(item)
            metadata = item.metadata || {}
            arguments = {
              title: metadata["title"], subtitle: metadata["subtitle"], author_names: Array(metadata["authors"]),
              year: year_of(metadata), subject: item, provisional: false, enrich: true,
              match: match_from_decision(::MatchDecision.find_by(id: state.match_decision_id))
            }
            arguments = if state.ol_work_key
              arguments.merge(open_library_work_key: state.ol_work_key, trust_work_key: true)
            else
              arguments.merge(providers: TEXT_PROVIDERS)
            end

            ::ActiveRecord::Base.transaction(requires_new: true) do
              result = importer.call(**arguments)
              book = result.item
              raise CreateFailed, "no book created: #{result.all_errors.join("; ")}" unless result.created? && book&.persisted?
              raise CreateFailed, "the new book got no author: #{result.all_errors.join("; ")}" unless ::Books::BookAuthor.exists?(book: book)

              book
            end
          end

          private

          def url_helpers = ::Rails.application.routes.url_helpers

          def book_holding(keys)
            return nil if keys.empty?

            ::Books::Book.joins(:identifiers)
              .where(identifiers: {identifier_type: ::Identifier.identifier_types[:books_work_openlibrary_id], value: keys})
              .order(:id).first
          end

          def book_created_from_text_since_match(item, state)
            metadata = item.metadata || {}
            title = ::Services::Lists::Wizard::Core::Signature.normalize(metadata["title"])
            names = Array(metadata["authors"]).map { |name| ::Services::Lists::Wizard::Core::Signature.normalize(name) }.compact_blank
            return nil if title.blank? || names.empty?

            # SQL narrows to books created since the row's Match that have an
            # author (a handful during one run); the comparison is in Ruby with
            # the wizard's own normalization, which SQL LOWER() cannot match
            # (curly quotes, Unicode width, spacing).
            ::Books::Book
              .where("books_books.created_at > ?", state.matched_at || item.created_at)
              .where(id: ::Books::BookAuthor.select(:book_id))
              .includes(:authors).order(:id)
              .find do |book|
                ::Services::Lists::Wizard::Core::Signature.normalize(book.title) == title &&
                  book.authors.flat_map { |author| [author.name, *Array(author.alternate_names)] }
                    .map { |name| ::Services::Lists::Wizard::Core::Signature.normalize(name) }.intersect?(names)
              end
          end

          # As Services::Books::GoodreadsImports::SettleEdition#match_from_decision:
          # the books the finder considered, and its decision.
          def match_from_decision(decision)
            considered = Array(decision&.candidates).filter_map do |snapshot|
              next unless snapshot["record_type"] == "Books::Book"

              book = ::Books::Book.find_by(id: snapshot["record_id"])
              ::DataImporters::Candidate.new(record: book) if book
            end
            ::DataImporters::Match.new(
              outcome: :unmatched, record: nil, confidence: decision&.confidence&.to_sym,
              decided_by: decision&.decided_by&.to_sym, reason: decision&.reason, candidates: considered, decision: decision
            )
          end

          def year_of(metadata)
            ::Services::Lists::Wizard::Core::Signature.year(metadata["year"])
          end
        end
      end
    end
  end
end
