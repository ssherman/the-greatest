# frozen_string_literal: true

# The goodreads step of the book workflow (enrichment spec section 4): finds
# the book's Goodreads page, re-checks it and applies it. book_facts and
# amazon wait on it.
#
# The step is resumable and makes at most one Goodreads fetch per execution.
# Every fetch takes a turn at Books::Goodreads::FetchGate, and a turn that is
# not yet due ends the execution with a wait, so the step never sleeps on the
# goodreads_fetch capsule. Where it has got to lives in step.result["progress"]
# (the engine merges a wait's result into the stored one, so the whole hash is
# written every time):
#
#   phase             "search" or "page"
#   query             the search text for the search phase
#   goodreads_book_id the page the page phase is on
#   origin            "known" (the book held the id) or "search" (a search pick)
#   due               true when the wait that ended the last execution was a
#                     reserved turn, so the next execution must not reserve again
#   followed_best     the main edition's page has been followed; never follow twice
#   searched_retry    the title-plus-surname search has been used
#   stray_id          the page followed away from, to fall back to if the main
#                     edition's page is not found (not in the spec's list)
#
# A match finishes as "matched" with {matched, goodreads_book_id, page_id}; a
# miss finishes as "no_match" or "rejected" with {matched: false} and one
# ledger row. An unavailable Goodreads or a down fetcher raises, so the
# coordinator retries with backoff.
module Workflows
  module Books
    module Steps
      class Goodreads
        GOODREADS_ID = "books_work_goodreads_id"
        PAGE_VERSION = ::Books::Goodreads::BookPage::VERSION

        def call(step:, run:, target:)
          @step = step
          @book = target
          @run = run
          @gate = ::Books::Goodreads::FetchGate.new
          @progress = (step.result || {})["progress"]&.dup || starting_progress

          loop do
            outcome = (@progress["phase"] == "page") ? page_phase : search_phase
            return outcome if outcome
          end
        end

        private

        # Each phase returns an Outcome to end the execution, or nil after
        # moving @progress on, to be run again.

        def starting_progress
          known = @book.identifiers.find_by(identifier_type: GOODREADS_ID)&.value
          base = {"phase" => "search", "query" => main_title, "origin" => "search", "due" => false,
                  "followed_best" => false, "searched_retry" => false}
          return base if known.blank?

          base.merge("phase" => "page", "goodreads_book_id" => known.to_i, "origin" => "known")
        end

        def search_phase
          search = cached_search
          unless search
            wait = fetch_turn
            return wait if wait

            result = ::Services::Books::GoodreadsPages::FetchSearch.call(query: @progress["query"])
            search = fetched(result.data[:outcome], result.data[:search])
            return search if search.is_a?(Workflows::Outcome)
          end

          survivors = ::Services::Books::GoodreadsEnrichment::CandidateFilter.call(book: @book, rows: search.candidate_rows)
          if survivors.empty?
            return miss("no_match") if @progress["searched_retry"] || surname.blank?

            @progress.update("searched_retry" => true, "query" => "#{main_title} #{surname}")
            return
          end

          pick = ::Services::Books::GoodreadsEnrichment::PickCandidate.call(book: @book, rows: survivors)
          return miss("no_match") unless pick

          @progress.merge!("phase" => "page", "goodreads_book_id" => pick.goodreads_book_id, "origin" => "search",
            "followed_best" => false, "stray_id" => nil)
          nil
        end

        def page_phase
          page = held_page
          unless page
            wait = fetch_turn
            return wait if wait

            existing = ::Books::GoodreadsPage.find_by(goodreads_book_id: @progress["goodreads_book_id"])
            result = ::Services::Books::GoodreadsPages::FetchPage.call(
              goodreads_book_id: @progress["goodreads_book_id"], refresh: !!existing&.outcome_found?
            )
            page = fetched(result.data[:outcome], result.data[:page])
            return page if page.is_a?(Workflows::Outcome)
          end

          return follow_best(page) if follow_best?(page)
          return fall_back_to_stray if !page.outcome_found? && @progress["followed_best"] && @progress["stray_id"]

          verdict = page.outcome_found? ? ::Services::Books::GoodreadsEnrichment::PageCheck.call(book: @book, page: page) : nil
          return apply(page) if verdict&.ok

          rejected
        end

        # The row when it can be used as it stands: a conclusive not_found, or a
        # found page with its HTML at the current parser version (re-read first
        # when it is at an older one). Nil means a fetch is needed.
        def held_page
          page = ::Books::GoodreadsPage.find_by(goodreads_book_id: @progress["goodreads_book_id"])
          return page if page&.outcome_not_found?
          return unless page&.outcome_found? && page.html.attached?

          page = ::Services::Books::GoodreadsPages::Reparse.call(page: page) if page.parser_version.to_i < PAGE_VERSION
          (page.parser_version.to_i >= PAGE_VERSION) ? page : nil
        end

        def cached_search
          ::Books::GoodreadsSearch.fresh.find_by(query: ::Books::GoodreadsSearch.normalize_value_for(:query, @progress["query"]))
        end

        # A search pick can be a stray edition; the work's main edition has the
        # page count, ISBN and description. Followed once, whatever it says.
        def follow_best?(page)
          best = page.best_book_id
          page.outcome_found? && best.present? && best != page.goodreads_book_id && !@progress["followed_best"]
        end

        def follow_best(page)
          @progress.merge!("followed_best" => true, "stray_id" => page.goodreads_book_id, "goodreads_book_id" => page.best_book_id)
          nil
        end

        def fall_back_to_stray
          @progress.update("goodreads_book_id" => @progress["stray_id"], "stray_id" => nil)
          nil
        end

        # A known id is unreliable (legacy stamped it on whatever it picked), so
        # a failed check retries as a search, once: the origin changes with it.
        def rejected
          if @progress["origin"] == "known"
            @progress.merge!("phase" => "search", "origin" => "search", "query" => main_title, "goodreads_book_id" => nil,
              "followed_best" => false, "stray_id" => nil, "searched_retry" => false)
            return
          end

          miss("rejected")
        end

        def apply(page)
          ::Services::Books::GoodreadsEnrichment::Apply.call(book: @book, page: page)
          Workflows::Outcome.succeeded("matched",
            {"matched" => true, "goodreads_book_id" => page.goodreads_book_id, "page_id" => page.id})
        end

        def miss(outcome)
          ::Services::Books::GoodreadsEnrichment::Ledger.record(book: @book, outcome: "unrecognized",
            reason: (outcome == "rejected") ? "rejected" : "no_match")
          Workflows::Outcome.succeeded(outcome, {"matched" => false})
        end

        # One gate turn. Nil means this execution may fetch; an Outcome is the
        # wait that ends it.
        def fetch_turn
          decision = ::Books::Goodreads::GateTurn.call(gate: @gate, due: @progress["due"] == true)
          case decision.action
          when :wait then wait_until(Time.current + decision.wait, due: true)
          when :refused
            wake = (decision.refusal == :daily_cap) ? Time.current.utc.tomorrow.beginning_of_day : blocked_until
            wait_until(wake, due: false)
          else
            spend_turn
          end
        end

        # The turn is used up the moment the fetch starts. A raise after it (a
        # fetch that fails, the pick, a crash) goes through Coordinator.fail, which
        # keeps no result, so the spent turn is written now: otherwise the retry
        # would find due: true, skip the reservation and fetch uncounted.
        def spend_turn
          @progress["due"] = false
          @step.update_columns(result: (@step.result || {}).merge("progress" => @progress))
          nil
        end

        # What a fetch handed back: the stored row, or the Outcome that ends the
        # execution. The turn is spent either way.
        def fetched(outcome, record)
          @progress["due"] = false
          ::Books::Goodreads::GateTurn.after_fetch(gate: @gate, outcome: outcome)
          case outcome
          when :blocked, :unparseable then wait_until(blocked_until, due: false)
          when :unavailable, :fetcher_down then raise StandardError, "Goodreads fetch for book #{@book.id} failed: #{outcome}"
          else record
          end
        end

        def blocked_until
          @gate.blocked_until || (Time.current + Rails.application.config.x.goodreads.block_cooldown)
        end

        def wait_until(time, due:)
          Workflows::Outcome.wait(time, result: {"progress" => @progress.merge("due" => due)})
        end

        def main_title = @book.title.to_s.split(":").first.to_s.strip

        def surname
          name = @book.authors.first&.name || Array(@run.options["author_names"]).first
          name.to_s.split.last
        end
      end
    end
  end
end
