# frozen_string_literal: true

module Services
  module Books
    module GoodreadsRebuild
      # For one derived book whose title or authors disagree with its Goodreads
      # export, decides what to do and records it as a repair verdict; nothing
      # is changed here (rebuild spec §4.1, §12). Either the right book already
      # exists, and the verdict is a merge of this book into it (keeping the
      # reset_source flag so the leftover wrong data is cleared), or it does
      # not, and the verdict is a fix_identity: reset this book and import it
      # again in place.
      #
      # The bar is zero wrong merges, so a merge is approved on its own only
      # when the target holds a verified Open Library work that the group's
      # evidence names, its title matches one of the group's export titles
      # exactly, and the group has no volume. Everything else waits for an
      # admin. The finder runs blinded (no Open Library, no legacy evidence),
      # and a match that is itself a book waiting for a fix is never a target.
      class DecideFix
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        # The one "needs a fix" rule; the batch job's SQL scope mirrors it and a test keeps them equal.
        def self.needs_fix?(survey)
          return false unless survey.coherent? || survey.lump?

          !(survey.title_agrees && survey.authors_agree && !survey.wrong_book)
        end

        def self.default_finder
          ::DataImporters::Books::Book::Finder.new(
            open_library: :none,
            identifier_sources: ::DataImporters::Books::Book::Finder::TRUSTED_IDENTIFIER_SOURCES
          )
        end

        def self.call(book:, survey:, finder: nil) = new(book: book, survey: survey, finder: finder).call

        def initialize(book:, survey:, finder:)
          @book = book
          @survey = survey
          @finder = finder
          @key = "rebuild:#{book.id}"
        end

        def call
          return done(:skipped) if Cohort.trusted?(@book.id) || !self.class.needs_fix?(@survey)

          kept = existing_verdict
          return done(:kept, kept) if kept

          @facts = ExportFacts.call(survey: @survey)
          unless rejected_merge?
            match = (@finder || self.class.default_finder).call(query: @facts.to_query, verify: true, subject: @book, exclude: @book)
            return record_merge(match) if eligible?(match)
          end
          record_fix
        end

        private

        def existing_verdict
          ::Books::RepairVerdict.where(subject_key: @key).find do |verdict|
            (verdict.fix_identity? || verdict.merge_books?) && !verdict.rejected?
          end
        end

        def rejected_merge?
          ::Books::RepairVerdict.exists?(kind: :merge_books, subject_key: @key, status: :rejected)
        end

        def eligible?(match)
          return false unless match&.matched? && match.record

          target = match.record
          return false if target.provisional?
          return true if Cohort.trusted?(target.id)

          other = ::Books::RebuildBookSurvey.find_by(book_id: target.id)
          other.present? && other.title_agrees && other.authors_agree && !other.wrong_book
        end

        def record_merge(match)
          target = match.record
          auto = auto_merge?(target)
          recorded = ::Services::Books::GoodreadsReplay::RecordVerdict.call(
            kind: :merge_books, subject_key: @key,
            payload: @facts.to_payload.merge("source_id" => @book.id, "target_id" => target.id, "reset_source" => true,
              "match_decision_id" => match.decision&.id),
            decided_by: if auto
                          :rule
                        else
                          ((match.decided_by == :ai) ? :ai : :rule)
                        end,
            confidence: auto ? :certain : match.confidence,
            reason: match.reason.presence || "an existing book matches the export",
            auto: auto, replace_superseded: true
          )
          done(:merge, recorded.data[:verdict])
        end

        def auto_merge?(target)
          @facts.volume.blank? && verified_work_key?(target) && title_agrees_exactly?(target)
        end

        def verified_work_key?(target)
          target.identifiers.where(identifier_type: :books_work_openlibrary_id, source: "open_library", value: @facts.ol_work_keys).exists?
        end

        def title_agrees_exactly?(target)
          theirs = Array(@survey.groups.first["titles"]).push(@facts.full_title).filter_map { |t| ::Services::Books::Verification::Check.title_key(t) }
          ours = [target.title, ("#{target.title}: #{target.subtitle}" if target.subtitle.present?)].filter_map { |t| ::Services::Books::Verification::Check.title_key(t) }
          (ours & theirs).any?
        end

        def record_fix
          auto = @facts.world_cat_agrees
          recorded = ::Services::Books::GoodreadsReplay::RecordVerdict.call(
            kind: :fix_identity, subject_key: @key, payload: @facts.to_payload.merge("book_id" => @book.id),
            decided_by: :rule, confidence: auto ? :high : :medium,
            reason: auto ? "no existing book found; WorldCat agrees" : "no existing book found; WorldCat does not confirm",
            auto: auto, replace_superseded: true
          )
          return done(:kept, recorded.data[:verdict]) if recorded.data[:outcome] == :suppressed

          done(:fix, recorded.data[:verdict])
        end

        def done(outcome, verdict = nil)
          Result.new(success?: true, data: {outcome: outcome, verdict: verdict}, errors: [])
        end
      end
    end
  end
end
