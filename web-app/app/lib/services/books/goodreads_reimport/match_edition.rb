# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReimport
      # Matches one Goodreads edition to our catalog and records it as a reimport_match verdict (re-import spec
      # 4.2). The finder runs blinded (no Open Library, trusted sources only); a mixed book stays matchable, since
      # the survey's mixed rule ignores titles and many such records are the right English book. The AI then
      # double-checks the candidates, because a finder match on a near-identical title can be a different volume or
      # an adaptation. Only an AI "high" on the finder's own pick, or on the book the reader is already on, is
      # approved without an admin; any other pick, doubt, or "none of these" next to a finder match waits for
      # review. A finder or AI failure records nothing, so the edition simply comes up again.
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

        def self.call(edition:, finder: nil, task_class: ::Services::Ai::Tasks::Books::SameWorkTask)
          new(edition: edition, finder: finder, task_class: task_class).call
        end

        def initialize(edition:, finder:, task_class:)
          @edition = edition
          @finder = finder
          @task_class = task_class
          @key = "reimport:edition:#{edition.id}"
        end

        def call
          existing = ::Books::RepairVerdict.find_by(kind: :reimport_match, subject_key: @key)
          # A rejected verdict is an admin's "no" and RecordVerdict would suppress any new one, so leave it alone.
          return done(:rejected, existing) if existing&.rejected? && existing.superseded_at.nil?
          return done(:kept, existing) if existing && !existing.rejected?

          @facts = EditionFacts.call(edition: @edition)
          match = (@finder || self.class.default_finder).call(query: @facts.to_query, verify: true, subject: @edition)
          return done(:retry) if match.decided_by == :fallback || Array(match.sources_failed).any?

          books = candidate_books(match)
          return record(match, books, nil) if books.empty?

          answer = @task_class.new(facts: @facts, books: books).call
          return done(:retry) unless answer.success?

          record(match, books, answer)
        end

        private

        # The finder's pick goes first. External-only candidates have no record and cannot be matched to. The book
        # the reader is on today always gets a place: the blinded finder misses it when the edition's title is a
        # translation, and without it the AI would answer "none" and a duplicate translated book would be created.
        # It is only a candidate; the AI still has to say it is the same work.
        def candidate_books(match)
          records = [match.record, *match.candidates.map(&:record)].compact.uniq(&:id)
          current = current_book
          return records.first(MAX_CANDIDATES) if current.nil? || records.first(MAX_CANDIDATES).any? { |book| book.id == current.id }

          records.reject { |book| book.id == current.id }.first(MAX_CANDIDATES - 1) + [current]
        end

        def current_book
          @current_book = ::Services::Books::GoodreadsReplay::Apply::MergedBook.call(@edition.book_id) unless defined?(@current_book)
          @current_book
        end

        def record(match, books, answer)
          ai = answer&.data || {}
          book_id = ai[:book_id]
          confidence = ai[:confidence]
          # The AI confirming the finder's pick, or the book the reader is already on, at high; anything else is reviewed.
          auto = if book_id.present?
            [match.record&.id, current_book&.id].compact.include?(book_id) && confidence == "high"
          else
            # "None of these" creates a book, so an AI answer needs high confidence; no candidates = rule only.
            match.unmatched? && (answer.nil? || confidence == "high")
          end
          payload = {
            "goodreads_edition_id" => @edition.id, "goodreads_book_id" => @edition.goodreads_book_id, "facts" => @facts.to_h,
            "outcome" => book_id.present? ? "matched" : "create", "book_id" => book_id,
            "match_decision_id" => match.decision&.id,
            "ai" => {"answer" => book_id, "confidence" => confidence, "reason" => ai[:reason]},
            "candidate_book_ids" => books.map(&:id)
          }
          recorded = ::Services::Books::GoodreadsReplay::RecordVerdict.call(
            kind: :reimport_match, subject_key: @key, payload: payload, decided_by: answer ? :ai : :rule,
            confidence: answer ? confidence : :certain, reason: answer ? ai[:reason] : "no candidate book found",
            ai_chat_id: answer&.ai_chat&.id, auto: auto, replace_superseded: true
          )
          outcome = recorded.data[:outcome]
          return done(outcome, recorded.data[:verdict]) if %i[suppressed kept].include?(outcome)

          done(book_id.present? ? :matched : :create, recorded.data[:verdict])
        end

        def done(outcome, verdict = nil)
          Result.new(success?: true, data: {outcome: outcome, verdict: verdict}, errors: [])
        end
      end
    end
  end
end
