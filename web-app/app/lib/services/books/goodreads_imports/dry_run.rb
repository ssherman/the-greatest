# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # Resolves a Goodreads export exactly as an import would (parse, find,
      # create) and reports every decision, then rolls all of it back. For
      # measuring the resolver on a real file before anything ships:
      #   bin/rails "books:goodreads:resolve_file[/path/to/export.csv]"
      #
      # The rollback covers rows, editions, decisions, books and authors. It
      # cannot take back outside calls: Open Library requests and matching AI
      # calls are made, and paid for, for real. Runs in a savepoint so the
      # rollback also works inside a caller's transaction (a test). The import
      # is created complete, never in progress, so it never collides with the
      # owner's real in-progress import.
      class DryRun
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(bytes:, user:, finder: nil, importer: ::DataImporters::Books::Book::Importer)
          new(bytes: bytes, user: user, finder: finder, importer: importer).call
        end

        def initialize(bytes:, user:, finder:, importer:)
          @bytes = bytes
          @user = user
          @finder = finder
          @importer = importer
        end

        def call
          parsed = ::Books::Goodreads::ExportFile.parse(@bytes)
          return Result.new(success?: false, data: {}, errors: parsed.errors) unless parsed.success?

          report = nil
          ActiveRecord::Base.transaction(requires_new: true) do
            import = ::Books::GoodreadsImport.create!(user: @user, source: :member, status: :complete)
            ParseRows.call(import: import, rows: parsed.data[:rows])
            ResolveImport.call(import: import, finder: @finder, importer: @importer)
            report = build_report(import.reload)
            raise ActiveRecord::Rollback
          end
          Result.new(success?: true, data: {report: report}, errors: [])
        end

        private

        def build_report(import)
          rows = import.rows.order(:row_number).to_a
          created_ids = import.records.created.where(record_type: "Books::Book").pluck(:record_id).to_set
          editions = ::Books::GoodreadsEdition.where(id: rows.filter_map(&:goodreads_edition_id))
            .includes(:match_decision, book: :authors).index_by(&:id)

          lines = [
            "Goodreads dry run: #{import.rows_count} rows, #{import.editions_count} editions. Nothing was saved.",
            "matched #{import.matched_count} | created #{import.created_count} | " \
              "waiting #{editions.values.count(&:verification_pending?)} | parked #{import.parked_count} | " \
              "flagged #{import.flagged_count} | failed rows #{rows.count(&:failed?)} | AI calls #{import.ai_calls_count}",
            ""
          ]
          rows.group_by(&:goodreads_edition_id).each do |edition_id, group|
            if edition_id.nil?
              group.each { |row| lines << "row #{row.row_number}: failed: #{row.error}" }
            else
              lines << "row #{group.map(&:row_number).join(",")}: #{describe(editions.fetch(edition_id), created_ids, group)}"
            end
          end
          lines.join("\n")
        end

        def describe(edition, created_ids, group)
          source = %(gr #{edition.goodreads_book_id} "#{edition.title}" by #{edition.primary_author})
          return "#{source} -> waiting for Goodreads verification" if edition.verification_pending?
          return "#{source} -> failed: #{group.filter_map(&:error).first}" if edition.resolved_at.nil?
          if edition.parked?
            return "#{source} -> parked: #{SettleEdition::PARKED_DETAIL.fetch(edition.verification.to_sym, edition.verification)}"
          end

          book = edition.book
          outcome = if created_ids.include?(book.id)
            %(created provisional Books::Book##{book.id} "#{book.title}" (#{edition.verification}))
          else
            %(matched Books::Book##{book.id} "#{book.title}" by #{book.authors.map(&:name).join(", ")})
          end
          "#{source} -> #{outcome}#{decision_note(edition.match_decision)}"
        end

        def decision_note(decision)
          return "" if decision.nil?

          note = " (#{decision.confidence}, #{decision.decided_by})"
          note += " [flagged: #{decision.reason}]" if decision.needs_review?
          note += " [sources failed: #{decision.sources_failed.join(", ")}]" if decision.sources_failed.any?
          note
        end
      end
    end
  end
end
