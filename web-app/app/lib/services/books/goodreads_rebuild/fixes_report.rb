# frozen_string_literal: true

module Services
  module Books
    module GoodreadsRebuild
      # Plain-text summary of the decide run for Shane to read before approving
      # anything: how many merges and fixes were found and how sure each is, how
      # many have been applied, any that failed, and samples with our title
      # beside the export's.
      module FixesReport
        module_function

        SAMPLE = 10
        ERRORS_SHOWN = 5
        KINDS = %i[merge_books fix_identity].freeze

        def call
          verdicts = ::Books::RepairVerdict.where(kind: KINDS).where("subject_key LIKE 'rebuild:%'")
          failed = verdicts.where.not(error: nil)
          lines = ["decided: #{verdicts.count}", "by kind, status and confidence:"]
          verdicts.group(:kind, :status, :confidence).count.sort_by { |key, _| key.map(&:to_s) }.each do |(kind, status, confidence), count|
            lines << "  #{kind} #{status} #{confidence || "no confidence"} #{count}"
          end
          lines << "applied: #{verdicts.where.not(applied_at: nil).count}"
          lines << "with an error: #{failed.count}"
          failed.order(:id).limit(ERRORS_SHOWN).each { |verdict| lines << "  #{verdict.subject_key}: #{verdict.error.to_s.lines.first.to_s.strip}" }
          merges(lines, verdicts.merge_books)
          fixes(lines, verdicts.fix_identity)
          enrichment(lines)
          lines.join("\n")
        end

        # Plain facts for deciding whether it is safe to raise the daily Goodreads cap.
        def enrichment(lines)
          runs = WorkflowRun.where(workflow: "books.book_enrichment", initiated_by: "goodreads_rebuild")
          steps = WorkflowStep.where(key: "goodreads", workflow_run_id: runs.select(:id))
          since = Time.current.utc.beginning_of_day
          gate = ::Books::Goodreads::FetchGate.new
          number = ActiveSupport::NumberHelper
          lines << "" << "enrichment of fixed books:"
          lines << "  runs started: #{runs.count}, finished: #{runs.where(status: %i[completed completed_with_failures]).count}, " \
            "failed: #{runs.completed_with_failures.count}"
          outcomes = {
            "found" => steps.where(outcome: "matched"),
            "missed" => steps.where(outcome: %w[no_match rejected blocked unparseable]),
            "failed" => steps.failed
          }
          counts = outcomes.map { |name, scope| "#{name}: #{scope.count} (today #{scope.where("finished_at >= ?", since).count})" }
          lines << "  Goodreads pages #{counts.join(", ")}"
          blocked = gate.blocked_until
          cap = number.number_to_delimited(Rails.application.config.x.goodreads.daily_fetch_cap)
          state = blocked ? "blocked until #{blocked.utc.strftime("%Y-%m-%d %H:%M UTC")}" : "gate not blocked"
          lines << "  Goodreads fetches today: #{fetch_usage(gate.usage, cap, number)} (#{state})"
        end

        # The gate keeps the day of its newest reservation, which late in the day
        # is tomorrow: then today's cap is used up and the count is tomorrow's.
        def fetch_usage(usage, cap, number)
          today = Time.current.utc.to_date
          return "the line has reached tomorrow: #{number.number_to_delimited(usage.count)} of tomorrow's fetches already reserved" if usage.day && usage.day > today

          "#{number.number_to_delimited((usage.day == today) ? usage.count : 0)} of #{cap}"
        end

        def sample(scope) = scope.order(Arel.sql("random()")).limit(SAMPLE)

        def merges(lines, scope)
          lines << "" << "merges (sample of #{SAMPLE}):"
          sample(scope).each do |verdict|
            source = ::Books::Book.find_by(id: verdict.payload["source_id"])
            target = ::Books::Book.find_by(id: verdict.payload["target_id"])
            lines << %(  book ##{verdict.payload["source_id"]} "#{source&.title}" -> ##{verdict.payload["target_id"]} "#{target&.title}" | ) +
              %(export: "#{verdict.payload["full_title"]}" [#{verdict.status} #{verdict.confidence}])
          end
        end

        def fixes(lines, scope)
          lines << "" << "fixes (sample of #{SAMPLE}):"
          sample(scope).each do |verdict|
            book = ::Books::Book.includes(:authors).find_by(id: verdict.payload["book_id"])
            lines << %(  ##{verdict.payload["book_id"]} "#{book&.title}" by #{book&.authors&.map(&:name)&.join(", ").presence || "nobody"} -> ) +
              %("#{verdict.payload["full_title"]}" by #{Array(verdict.payload["author_names"]).join(", ")} [#{verdict.status} #{verdict.confidence}])
          end
        end
      end
    end
  end
end
