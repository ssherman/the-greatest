# frozen_string_literal: true

module Services
  module Books
    module GoodreadsRebuild
      # For one derived book whose title or authors disagree with its Goodreads
      # export, decides what to do and records it as a repair verdict; nothing
      # is reset or merged here (rebuild spec §4.1, §12); the one thing written besides the verdict is
      # a same-person export spelling, kept as an author's alternate name. Either the right book already
      # exists, and the verdict is a merge of this book into it (keeping the
      # reset_source flag so the leftover wrong data is cleared), or it does
      # not, and the verdict is a fix_identity: reset this book and import it
      # again in place.
      #
      # The bar is zero wrong merges, so a merge is approved on its own only
      # when the target holds a verified Open Library work that the group's
      # evidence names, its title matches one of the group's export titles
      # exactly, the group has no volume, and nobody has marked
      # the pair as not a duplicate. Everything else waits for an
      # admin. The finder runs blinded (no Open Library, no legacy evidence),
      # and a match that is itself a book waiting for a fix is never a target.
      class DecideFix
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        # A volume word followed by its number ("Book Five", "Vol. 7", "Part II"). Check.names_volume?
        # is too loose for whole titles ("The Book Thief", "Band of Brothers", "1984").
        NUMBER_WORDS = %w[one two three four five six seven eight nine ten eleven twelve first second third].join("|")
        VOLUME_SHAPE = /\b(?:vols?|volumes?|books?|parts?|tome|teil|band|livre|tomo|parte|libro|buch|tom|livro)\b\.?\s*(?:#?\d+|[ivxlcdm]+|#{NUMBER_WORDS})\b|#\s*\d/i

        # The one "needs a fix" rule; the batch job's SQL scope mirrors it and a test keeps them equal.
        # A lump (Goodreads rows of several different books) never needs one here: deciding it from its
        # biggest group would move every other group's readers onto that book, so it waits for the split step.
        def self.needs_fix?(survey)
          return false unless survey.coherent?

          !(survey.title_agrees && survey.authors_agree && !survey.wrong_book)
        end

        def self.default_finder
          ::DataImporters::Books::Book::Finder.new(
            open_library: :none,
            identifier_sources: ::DataImporters::Books::Book::Finder::TRUSTED_IDENTIFIER_SOURCES,
            alternate_title_sources: ::DataImporters::Books::Book::Finder::TRUSTED_ALTERNATE_TITLE_SOURCES
          )
        end

        def self.call(book:, survey:, finder: nil, task_class: nil) = new(book: book, survey: survey, finder: finder, task_class: task_class).call

        def initialize(book:, survey:, finder:, task_class: nil)
          @book = book
          @survey = survey
          @finder = finder
          @task_class = task_class
          @key = "rebuild:#{book.id}"
        end

        def call
          return done(:skipped) if Cohort.trusted?(@book.id) || !self.class.needs_fix?(@survey)

          kept = existing_verdict
          return done(:kept, kept) if kept

          @facts = ExportFacts.call(survey: @survey)
          authors = match_authors
          return done(:retry) unless authors.success?

          @author_links = authors.data[:links]
          return record_same_author if @survey.title_agrees && authors.data[:all_matched] && own_title_agrees?

          unless rejected_merge?
            match = (@finder || self.class.default_finder).call(query: @facts.to_query, verify: true, subject: @book, exclude: @book)
            return done(:retry) if failed?(match)
            return record_merge(match) if eligible?(match)
          end
          record_fix
        end

        private

        # Whether the export's author names are the book's own authors, spelled differently
        # ("Kurt Vonnegut" for "Kurt Vonnegut Jr."), is a question of who the person is, so the AI answers it.
        def match_authors
          args = {book: @book, facts: @facts}
          args[:task_class] = @task_class if @task_class
          MatchAuthors.call(**args)
        end

        # survey.title_agrees also counts a legacy alternate title, which is a guess and never evidence:
        # the shortcut needs the book's own title, or an alternate title someone trusted, to equal the export's.
        def own_title_agrees?
          return true if derived_title_matches?(@book)

          trusted = @book.alternate_title_records.kept.where(source: ::DataImporters::Books::Book::Finder::TRUSTED_ALTERNATE_TITLE_SOURCES).pluck(:title)
          wanted = export_titles.flat_map { |title| [title, title.sub(ExportFacts::SERIES_SUFFIX, "")] }.filter_map { |t| ::Services::Books::Verification::Check.title_key(t) }
          (trusted.filter_map { |t| ::Services::Books::Verification::Check.title_key(t) } & wanted).any?
        end

        # The right book with the right title and the same people under other spellings: nothing is
        # recorded or reset. The export spelling is kept as an alternate name, which also lets
        # the next run match the names without asking again.
        def record_same_author
          ::Books::Author.where(id: @author_links.values).find_each do |author|
            spellings = @author_links.select { |_, id| id == author.id }.keys
            held = ::Services::Text::PersonNameKey.all([author.name, *Array(author.alternate_names)])
            missing = spellings.reject { |spelling| held.include?(::Services::Text::PersonNameKey.call(spelling)) }
            author.update!(alternate_names: (Array(author.alternate_names) + missing).uniq) if missing.any?
          end
          done(:same_author)
        end

        def existing_verdict
          ::Books::RepairVerdict.where(subject_key: @key).find do |verdict|
            (verdict.fix_identity? || verdict.merge_books?) && !verdict.rejected?
          end
        end

        # Only a current rejection is an admin's "no"; one retired while the record was a lump
        # (rejected and superseded, RetireLumpVerdicts) says nothing about the right book.
        def rejected_merge?
          ::Books::RepairVerdict.current.exists?(kind: :merge_books, subject_key: @key, status: :rejected)
        end

        # A finder that fell back or lost a source did not search properly; "nothing found"
        # would be a guess, so record nothing and let the next run try again.
        def failed?(match)
          match.present? && (match.decided_by == :fallback || Array(match.sources_failed).any?)
        end

        def eligible?(match)
          return false unless match&.matched? && match.record

          target = match.record
          return false if target.provisional?
          return false if volume_mismatch?(target)
          return true if Cohort.trusted?(target.id)

          other = ::Books::RebuildBookSurvey.find_by(book_id: target.id)
          return false unless other.present? && other.title_agrees && other.authors_agree && !other.wrong_book

          # Our page should be the English one when an English edition exists. A derived record
          # (made by legacy, on no list) can be titled in another language while its own survey
          # still agrees, so only an exact title match lets readers merge into it; otherwise the
          # book is fixed in place and stage two's dedupe keeps the English page.
          return true if derived_title_matches?(target)

          @refused = "the existing book has a different (possibly translated) title"
          false
        end

        def derived_title_matches?(target)
          return true if title_agrees_exactly?(target)

          stripped = export_titles.map { |title| title.sub(ExportFacts::SERIES_SUFFIX, "") }.filter_map { |t| ::Services::Books::Verification::Check.title_key(t) }
          ours = [target.title, target_full_title(target)].filter_map { |t| ::Services::Books::Verification::Check.title_key(t) }
          (ours & stripped).any?
        end

        # The AI matched across volumes ("Book Five" to "Book 1", a complete series
        # to Vol. 7, "1Q84 Book 1" to the whole novel). Once either side names a
        # volume or a set, only an exact title agreement makes it the same book.
        def volume_mismatch?(target)
          titles = export_titles.map { |title| title.sub(ExportFacts::SERIES_SUFFIX, "") } + [target.title, target_full_title(target)].compact
          return false unless titles.any? { |title| volume_shaped?(title) }
          return false if title_agrees_exactly?(target)

          @refused = "the matched book and the export differ on a volume or set"
          true
        end

        def volume_shaped?(title)
          title.match?(VOLUME_SHAPE) || title.match?(::Services::Books::Verification::EditionCheck::SET_WORDS)
        end

        def export_titles
          (Array(@survey.groups.first["titles"]) + [@facts.full_title]).compact_blank
        end

        def target_full_title(target)
          "#{target.title}: #{target.subtitle}" if target.subtitle.present?
        end

        def record_merge(match)
          target = match.record
          auto = auto_merge?(target)
          reason = match.reason.presence || "an existing book matches the export"
          reason = "#{reason} (held back: an admin earlier marked these two as not a duplicate)" if marked_not_duplicate?(target)
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
            reason: reason,
            auto: auto, replace_superseded: true
          )
          done(:merge, recorded.data[:verdict])
        end

        def auto_merge?(target)
          @facts.volume.blank? && !marked_not_duplicate?(target) &&
            verified_work_key?(target) && title_agrees_exactly?(target)
        end

        # A person already judged these two books different; that stands over any rule.
        def marked_not_duplicate?(target)
          ::DuplicateCandidate.not_duplicate?(item_type: "Books::Book", ids: [@book.id, target.id])
        end

        def verified_work_key?(target)
          target.identifiers.where(identifier_type: :books_work_openlibrary_id, source: "open_library", value: @facts.ol_work_keys).exists?
        end

        def title_agrees_exactly?(target)
          theirs = export_titles.filter_map { |t| ::Services::Books::Verification::Check.title_key(t) }
          ours = [target.title, target_full_title(target)].filter_map { |t| ::Services::Books::Verification::Check.title_key(t) }
          (ours & theirs).any?
        end

        def record_fix
          auto = @facts.world_cat_agrees
          reason = auto ? "no existing book found; WorldCat agrees" : "no existing book found; WorldCat does not confirm"
          reason = "merge refused: #{@refused}; #{reason}" if @refused
          recorded = ::Services::Books::GoodreadsReplay::RecordVerdict.call(
            kind: :fix_identity, subject_key: @key, payload: @facts.to_payload.merge("book_id" => @book.id, "author_links" => @author_links),
            decided_by: :rule, confidence: auto ? :high : :medium,
            reason: reason,
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
