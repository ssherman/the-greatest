# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReimport
      # Runs the approved re-import verdicts (re-import spec 8), one kind at a time in HANDLERS order: matches
      # and creates, then the rows, the guesses, the identifier strips, the mixed-book deletes (which need
      # everything before them), and the authors. A call takes the approved, current, unapplied verdicts of the
      # first kind that has any, in id order, up to `limit`.
      #
      # A verdict whose handler answers :noop stays unapplied (the answer may change: a mixed book that still
      # holds an entry), unless the handler says the answer is final. So that one waiting verdict does not hold
      # every later kind back, a call moves on to the next kind once everything left in the current one has
      # been tried in this call. `remaining` counts what the limit cut off; the job queues another call while
      # it is above zero.
      module Apply
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        HANDLERS = {
          reimport_match: Match,
          reimport_row: Row,
          reimport_guess: Guess,
          reimport_strip: Strip,
          reimport_mixed: Mixed,
          reimport_author: Author
        }.freeze

        def self.call(limit: 500) = Run.new(limit).call

        class Run
          include GoodreadsReplay::HandlerRun

          def initialize(limit)
            @limit = limit
            @tally = {applied: 0, noop: 0, failed: 0}
            @reasons = Hash.new(0)
            @tried = Set.new
            @rankings = Set.new
            @follow_ups = Set.new
          end

          def call
            cut_off = false
            HANDLERS.each do |kind, handler|
              cut_off = work(kind, handler)
              break if cut_off
            end
            queue_follow_ups(@rankings, @follow_ups)
            data = @tally.merge(remaining: cut_off ? pending.count : 0, noop_reasons: @reasons.to_h)
            Result.new(success?: true, data: data, errors: [])
          end

          private

          def pending(kind = nil)
            scope = ::Books::RepairVerdict.approved.current.unapplied.where.not(id: @tried.to_a)
            kind ? scope.where(kind: kind) : scope.where(kind: HANDLERS.keys)
          end

          # Tries one kind's verdicts; true when the limit stopped it with some left.
          def work(kind, handler)
            budget = @limit - @tried.size
            return pending(kind).exists? if budget <= 0

            pending(kind).order(:id).limit(budget).each do |verdict|
              @tried << verdict.id
              apply(verdict, handler)
            end
            pending(kind).exists?
          end

          def apply(verdict, handler)
            result = call_handler(verdict, handler)
            data = result.data
            outcome = data[:outcome]
            @rankings.merge(Array(data[:ranking_configuration_ids]) + Array(data[:reweigh_configuration_ids]))
            @follow_ups.merge(Array(data[:follow_ups]))
            done = outcome == :applied || (outcome == :noop && data[:final])
            verdict.update!(applied_at: done ? Time.current : verdict.applied_at, error: nil)
            @tally[(outcome == :applied) ? :applied : :noop] += 1
            @reasons[data[:reason]] += 1 if outcome == :noop && data[:reason]
          rescue *POSTGRES_ERRORS
            raise
          rescue => e
            verdict.update!(error: "#{e.class}: #{e.message}")
            @tally[:failed] += 1
          end
        end
      end
    end
  end
end
