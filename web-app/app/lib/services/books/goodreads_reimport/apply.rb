# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReimport
      # Runs the approved re-import verdicts (re-import spec 8), one kind at a time in HANDLERS order, each kind
      # in id order. One chain of calls walks that order ONCE: `after` is the cursor ({"kind", "id"}) of the last
      # verdict the previous call tried, and a call takes the approved, current, unapplied verdicts strictly after
      # it, up to `limit`. data[:cursor] is the last one tried, or nil once the walk reached the end.
      #
      # A verdict whose handler answers a non-final :noop (a mixed book that still holds an entry) stays
      # unapplied and is not offered again in this chain, so any number of them cannot hold later verdicts or
      # later kinds back, and the chain always ends. A new chain starts from the rake task or cron with no cursor.
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

        def self.call(limit: 500, after: nil) = Run.new(limit, after).call

        class Run
          include GoodreadsReplay::HandlerRun

          def initialize(limit, after)
            @limit = limit
            @after = after
            @tally = {applied: 0, noop: 0, failed: 0}
            @reasons = Hash.new(0)
            @rankings = Set.new
            @follow_ups = Set.new
          end

          def call
            last = nil
            tried = 0
            HANDLERS.each do |kind, handler|
              floor = floor_for(kind)
              next if floor.nil?

              verdicts = pending(kind, floor).limit(@limit - tried).to_a
              verdicts.each do |verdict|
                apply(verdict, handler)
                last = {"kind" => kind.to_s, "id" => verdict.id}
              end
              tried += verdicts.size
              break if tried >= @limit
            end
            cursor = (last if tried >= @limit && more_after?(last))
            queue_follow_ups(@rankings, @follow_ups)
            Result.new(success?: true, data: @tally.merge(cursor: cursor, noop_reasons: @reasons.to_h), errors: [])
          end

          private

          # Lowest verdict id still to look at in this kind; nil when the cursor is already past the kind.
          def floor_for(kind)
            return 0 unless @after

            order = HANDLERS.keys
            here, there = order.index(kind), order.index(@after["kind"].to_sym)
            return nil if here < there

            (here == there) ? @after["id"].to_i : 0
          end

          def pending(kind, floor)
            ::Books::RepairVerdict.approved.current.unapplied.where(kind: kind).where("id > ?", floor).order(:id)
          end

          def more_after?(last)
            return false unless last

            HANDLERS.keys.drop(HANDLERS.keys.index(last["kind"].to_sym)).any? do |kind|
              pending(kind, (kind.to_s == last["kind"]) ? last["id"] : 0).exists?
            end
          end

          def apply(verdict, handler)
            result = call_handler(verdict, handler)
            data = result.data
            outcome = data[:outcome]
            @rankings.merge(Array(data[:ranking_configuration_ids]) + Array(data[:reweigh_configuration_ids]))
            @follow_ups.merge(Array(data[:follow_ups]))
            done = outcome == :applied || (outcome == :noop && data[:final])
            if outcome == :noop && data[:final]
              verdict.update_columns(payload: verdict.payload.merge("closed_reason" => data[:reason]))
            end
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
