# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReimport
      # Matches one Goodreads edition to our catalog and records it as a reimport_match verdict (re-import spec
      # 4.2). The finder runs blinded (no Open Library, trusted sources only); a mixed book stays matchable, since
      # the survey's mixed rule ignores titles and many such records are the right English book. The AI then
      # double-checks the candidates, because a finder match on a near-identical title can be a different volume or
      # an adaptation. Only an AI "high" on the finder's own pick, or on the book the reader is already on when the
      # finder picked nothing and it is not mixed, is approved without an admin; any other pick, doubt, or "none of
      # these" next to a finder match or a trusted candidate waits for review. A finder or AI failure records nothing, so the edition simply
      # comes up again.
      class MatchEdition
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        MAX_CANDIDATES = 6

        def self.default_finder
          ::DataImporters::Books::Book::Finder.new(
            open_library: :none,
            identifier_sources: ::DataImporters::Books::Book::Finder::TRUSTED_IDENTIFIER_SOURCES,
            alternate_title_sources: ::DataImporters::Books::Book::Finder::TRUSTED_ALTERNATE_TITLE_SOURCES
          )
        end

        # The "create a new book" verdicts recorded before the English-title search, which recheck: true may replace:
        # unreviewed, unapplied and current, with no English check yet.
        def self.recheckable
          ::Books::RepairVerdict.current.where(kind: :reimport_match, status: [:approved, :proposed], reviewed_at: nil, applied_at: nil)
            .where("payload->>'outcome' = 'create'").where.not("payload ? 'english_title'")
        end

        # recheck: match an edition whose verdict is recheckable again, and replace that verdict only if it is still
        # recheckable when the new one is written (RecheckCreatesJob). Until then the old verdict is untouched, so an
        # interrupted recheck leaves it as it was, and a review made meanwhile wins.
        def self.call(edition:, finder: nil, task_class: ::Services::Ai::Tasks::Books::SameWorkTask,
          english_task_class: ::Services::Ai::Tasks::Books::EnglishTitleTask, recheck: false)
          new(edition: edition, finder: finder, task_class: task_class, english_task_class: english_task_class, recheck: recheck).call
        end

        def initialize(edition:, finder:, task_class:, english_task_class:, recheck:)
          @edition = edition
          @finder = finder
          @task_class = task_class
          @english_task_class = english_task_class
          @recheck = recheck
          @key = "reimport:edition:#{edition.id}"
        end

        def call
          existing = ::Books::RepairVerdict.find_by(kind: :reimport_match, subject_key: @key)
          # A rejected verdict is an admin's "no" and RecordVerdict would suppress any new one, so leave it alone.
          return done(:rejected, existing) if existing&.rejected? && existing.superseded_at.nil?
          if @recheck
            return done(:kept, existing) unless existing && self.class.recheckable.exists?(id: existing.id)
          elsif existing && !existing.rejected?
            return done(:kept, existing)
          end

          @facts = EditionFacts.call(edition: @edition)
          match = finder.call(query: @facts.to_query, verify: true, subject: @edition)
          return done(:retry) if failed?(match)

          books = candidate_books(records(match))
          answer = nil
          if books.any?
            answer = @task_class.new(facts: @facts, books: books).call
            return done(:retry) unless answer.success?
          end
          return record(match, books, answer) if answer&.data&.dig(:book_id)

          english_search(match, books, answer)
        end

        private

        def finder = @finder || self.class.default_finder

        def failed?(match) = match.decided_by == :fallback || Array(match.sources_failed).any?

        # External-only candidates have no record and cannot be matched to; the finder's pick goes first.
        def records(match) = [match.record, *match.candidates.map(&:record)].compact

        # Before "none" creates a book, a second look: the finder searches an English catalog, so a translated
        # edition with no current book finds nothing and would become a non-English duplicate (Der talentierte
        # Mr. Ripley next to The Talented Mr. Ripley). The AI names the English edition's title; the finder searches
        # with it; any new books go first and the same-work AI is asked again, with the English finder's pick as the
        # one an AI "high" may confirm on its own.
        def english_search(match, books, answer)
          english = @english_task_class.new(facts: @facts).call
          return done(:retry) unless english.success?

          @english_title = english.data.slice(:title, :confidence, :reason)
          title = english.data[:title]
          return record(match, books, answer) if title.blank?

          english_match = finder.call(query: english_query(title), verify: true, subject: @edition)
          return done(:retry) if failed?(english_match)

          found = records(english_match).reject { |book| books.any? { |known| known.id == book.id } }
          return record(match, books, answer) if found.empty?

          books = candidate_books(found + books)
          second = @task_class.new(facts: @facts, books: books, english_title: title).call
          return done(:retry) unless second.success?

          record(english_match, books, second, unmatched: match.unmatched? && english_match.unmatched?)
        end

        # The English title and the primary author; the edition's own ISBNs and Goodreads id belong to the translation.
        def english_query(title)
          ::DataImporters::Books::Book::ImportQuery.new(
            title: title, author_names: [@facts.primary_author].compact, year: @facts.year,
            context_author_names: Array(@facts.author_names) - [@facts.primary_author],
            series_name: @facts.series_name, series_number: @facts.series_number
          )
        end

        # The book the reader is on today always gets a place: the blinded finder misses it when the edition's title
        # is a translation, and without it the AI would answer "none" and a duplicate translated book would be
        # created. It is only a candidate; the AI still has to say it is the same work.
        def candidate_books(found)
          records = found.uniq(&:id)
          current = current_book
          return records.first(MAX_CANDIDATES) if current.nil? || records.first(MAX_CANDIDATES).any? { |book| book.id == current.id }

          records.reject { |book| book.id == current.id }.first(MAX_CANDIDATES - 1) + [current]
        end

        def trusted_current_book_id
          current_book&.id unless current_book.nil? || MixedBooks.include?(current_book.id)
        end

        def current_book
          @current_book = ::Services::Books::GoodreadsReplay::Apply::MergedBook.call(@edition.book_id) unless defined?(@current_book)
          @current_book
        end

        # unmatched: whether no finder picked a book (both searches, after an English search).
        def record(match, books, answer, unmatched: match.unmatched?)
          ai = answer&.data || {}
          book_id = ai[:book_id]
          confidence = ai[:confidence]
          # The AI confirming the finder's pick at high, or the book the reader is already on when the finder picked
          # nothing and it is not a mixed book (a legacy link to a mixed book is the suspect kind). The AI choosing
          # the current book over a different finder pick is a disagreement, so reviewed.
          auto = if book_id.present?
            confidence == "high" && book_id == (match.record&.id || trusted_current_book_id)
          else
            # "None of these" creates a book, so an AI answer needs high confidence, and none of the candidates may be a
            # trusted book (pre-import, new-app, or on a curated list): a wrong "none" next to one duplicates a book
            # readers know, as Flowers for Algernon nearly was when the AI read its catalog year as the short story's.
            # No candidates = rule only.
            unmatched && (answer.nil? || (confidence == "high" && books.none? { |book| trusted_book?(book) }))
          end
          payload = {
            "goodreads_edition_id" => @edition.id, "goodreads_book_id" => @edition.goodreads_book_id, "facts" => @facts.to_h,
            "outcome" => book_id.present? ? "matched" : "create", "book_id" => book_id,
            "match_decision_id" => match.decision&.id,
            "ai" => {"answer" => book_id, "confidence" => confidence, "reason" => ai[:reason]},
            "candidate_book_ids" => books.map(&:id)
          }
          payload["english_title"] = @english_title.stringify_keys if @english_title
          attributes = {
            kind: :reimport_match, subject_key: @key, payload: payload, decided_by: answer ? :ai : :rule,
            confidence: answer ? confidence : :certain, reason: answer ? ai[:reason] : "no candidate book found",
            ai_chat_id: answer&.ai_chat&.id, auto: auto, replace_superseded: true
          }
          recorded = @recheck ? replace_recheckable(attributes) : ::Services::Books::GoodreadsReplay::RecordVerdict.call(**attributes)
          outcome = recorded.data[:outcome]
          return done(outcome, recorded.data[:verdict]) if %i[suppressed kept].include?(outcome)

          done(book_id.present? ? :matched : :create, recorded.data[:verdict])
        end

        # The old verdict is locked and checked again before it is replaced: a review or apply made while this edition
        # was being matched keeps it (RecordVerdict updates an unreviewed verdict in place).
        def replace_recheckable(attributes)
          ::Books::RepairVerdict.transaction do
            locked = self.class.recheckable.lock.find_by(subject_key: @key)
            next GoodreadsReplay::RecordVerdict::Result.new(success?: true, data: {verdict: nil, outcome: :kept}, errors: []) unless locked

            ::Services::Books::GoodreadsReplay::RecordVerdict.call(**attributes)
          end
        end

        def trusted_book?(book) = ::Services::Books::GoodreadsRebuild::Cohort.trusted?(book.id)

        def done(outcome, verdict = nil)
          Result.new(success?: true, data: {outcome: outcome, verdict: verdict}, errors: [])
        end
      end
    end
  end
end
