# frozen_string_literal: true

# books.author_enrichment (spec section 6.1): today's chained author jobs
# (Wikidata, then VIAF on a miss, then a forced Wikidata run for a VIAF QID,
# then the AI step) as one definition. Each step wraps an existing service in
# an adapter under Steps; none enqueues its successor.
#
# Run options read by the steps: "refresh" (default false), "allow_research"
# (default true), "skip_ai_if_ran" (default false), and the engine's "start_at".
# The backfill starts at viaf for an author Wikidata already processed.
module Workflows
  module Books
    class AuthorEnrichment < Workflows::Definition
      QUEUE = :author_chain

      workflow "books.author_enrichment"
      version 1
      target_class ::Books::Author

      add_step key: :wikidata, queue: QUEUE, lease: 5.minutes,
        adapter: Steps::Wikidata.new(refresh_from: :options)

      # Runs after a Wikidata miss, or when the run starts here (Wikidata was
      # not requested). Any other Wikidata outcome ends the search for a match.
      add_step key: :viaf, queue: QUEUE, lease: 5.minutes, waits_on: {wikidata: :finish},
        skip_if: ->(run) { "not_needed" unless %w[unmatched not_requested].include?(run.step(:wikidata).outcome) },
        adapter: Steps::Viaf.new

      # A QID VIAF found, once, forced since the earlier miss counts as
      # processed. A decision flagged needs_review is not sent back: the Wikidata
      # run's held-id path would treat the stamped id as independent evidence and
      # record a certain match, turning an uncertain VIAF pick into a certain
      # Wikidata one.
      add_step key: :wikidata_via_viaf, queue: QUEUE, lease: 5.minutes, waits_on: {viaf: :finish},
        skip_if: lambda { |run|
          viaf = run.step(:viaf)
          sent_back = viaf.succeeded? && viaf.result["wikidata_qid"].present? && !viaf.result["needs_review"]
          "not_needed" unless sent_back
        },
        adapter: Steps::Wikidata.new(refresh: true)

      # Released edges, not finished ones: a VIAF step that waits far off releases
      # itself, and the AI step must not wait with it (VIAF patience).
      # on_terminal is the legacy hand-off of the books waiting for this author
      # (Services::Books::DeferredEnrichment), on success and on exhausted
      # retries alike. Transitional: Task 14 replaces it with the book workflow's
      # own wait.
      add_step key: :author_facts, queue: QUEUE, lease: 15.minutes,
        waits_on: {wikidata: :release, viaf: :release, wikidata_via_viaf: :release},
        skip_if: lambda { |run|
          next unless run.options["skip_ai_if_ran"]

          "already_ran" if ::Services::Books::Authors::LedgerRun.ai_step_ran_ids([run.enrichable_id]).any?
        },
        on_terminal: ->(step, author) { ::Books::Authors::EnrichJob.hand_off(author.id) },
        adapter: Steps::AuthorFacts.new

      # The AI step again, only when a VIAF QID's Wikidata facts arrived after the
      # AI step started, so it ran without them (EnrichAuthor skips a complete
      # author, so this fills blanks only). "Started" is started_at, not the
      # finish: a follow-up that lands while the AI step is still running missed
      # it too. A skipped AI step (already_ran) never started, so its nil
      # started_at counts as early: it ran in an earlier era without this QID,
      # and the legacy chain ran it once more after the follow-up (spec 6.1).
      add_step key: :author_facts_late, queue: QUEUE, lease: 15.minutes,
        waits_on: {wikidata_via_viaf: :finish, author_facts: :finish},
        skip_if: lambda { |run|
          follow_up = run.step(:wikidata_via_viaf)
          facts = run.step(:author_facts)
          late = follow_up.succeeded? && (facts.started_at.nil? || facts.started_at < follow_up.finished_at)
          "not_needed" unless late
        },
        adapter: Steps::AuthorFacts.new

      # Plans an author run and dispatches what is ready once the caller's
      # transaction commits. Returns the run: the new one, or the active one when
      # the author already has a run (unless supersede cancels it first).
      def self.start(author, initiated_by:, options: {}, start_after: nil, parent_run: nil, supersede: false)
        result = Workflows::Planner.call(definition: self, enrichable: author, initiated_by: initiated_by, options: options,
          start_after: start_after, parent_run: parent_run, supersede: supersede)
        raise ArgumentError, result.errors.join("; ") unless result.success?

        Workflows::Dispatcher.after_commit(result.data[:ready_steps])
        result.data[:run]
      end
    end
  end
end
