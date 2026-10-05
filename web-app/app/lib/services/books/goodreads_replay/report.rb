# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      # The replay's measurement (Goodreads import spec §12.9), as markdown for
      # docs/data-quality/goodreads-replay.md. It covers imports by status,
      # rows by finding with the agreement rate, verdicts by kind, decider and
      # confidence, and the matching AI calls. Read-only. The author check's AI
      # calls are printed by books:goodreads_replay:duplicates, one per name
      # group, rather than counted here.
      class Report
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        COMMAND = 'bin/rails "books:goodreads_replay:report[../docs/data-quality/goodreads-replay.md]"'
        AGREEING = %w[agrees duplicate].freeze
        FINAL = %w[agrees duplicate disagrees unmatched].freeze

        def self.call(now: Time.current)
          new(now: now).call
        end

        def self.sample(kind:, count:)
          ::Books::RepairVerdict.approved.where(kind: kind, reviewed_at: nil).order(Arel.sql("random()")).limit(count)
            .map { |verdict| "##{verdict.id} #{verdict.summary} (#{verdict.decided_by}, #{verdict.confidence}) — #{verdict.reason}" }
        end

        def initialize(now:)
          @now = now
        end

        def call
          lines = header + imports + rows + verdicts + ai_calls
          Result.new(success?: true, data: {markdown: lines.join("\n") + "\n"}, errors: [])
        end

        private

        def header
          ["# Goodreads legacy replay", "",
            "**Measured #{@now.to_date.iso8601}** against `#{ActiveRecord::Base.connection.current_database}`, " \
              "with `auto_apply` #{Rails.configuration.x.goodreads_replay.auto_apply ? "on" : "off"}.", "",
            "```bash", "cd web-app", COMMAND, "```", "",
            "Read-only. Produced by `Services::Books::GoodreadsReplay::Report` after a replay pass " \
              "(`docs/features/goodreads-import.md`, \"Legacy replay\").", ""]
        end

        def imports
          counts = ::Books::GoodreadsImport.legacy_replay.group(:status).count
          ["## Imports", "", "| Status | Imports |", "|---|---:|"] +
            counts.sort.map { |status, count| "| #{status} | #{count} |" } + [""]
        end

        def rows
          counts = replay_rows.group(:replay_finding).count
          with_choice = FINAL.sum { |finding| counts.fetch(finding, 0) }
          agreeing = AGREEING.sum { |finding| counts.fetch(finding, 0) }
          rate = with_choice.zero? ? "n/a" : "#{(100.0 * agreeing / with_choice).round(1)}%"
          ["## Rows", "", "Agreement: **#{rate}** (#{agreeing} of #{with_choice} rows with a legacy choice)", "",
            "| Finding | Rows |", "|---|---:|"] +
            counts.sort_by { |finding, _| finding.to_s }
              .map { |finding, count| "| #{finding ? finding.tr("_", " ") : "not compared yet"} | #{count} |" } + [""]
        end

        def verdicts
          table = ::Books::RepairVerdict.group(:kind, :decided_by, :confidence, :status).count
          applied = ::Books::RepairVerdict.where.not(applied_at: nil).group(:kind, :decided_by, :confidence).count
          keys = table.keys.map { |kind, decider, confidence, _| [kind, decider, confidence] }.uniq.sort_by { |key| key.map(&:to_s) }
          ["## Verdicts", "", "| Kind | Decided by | Confidence | Proposed | Approved | Rejected | Applied |", "|---|---|---|---:|---:|---:|---:|"] +
            keys.map do |kind, decider, confidence|
              counts = %w[proposed approved rejected].map { |status| table.fetch([kind, decider, confidence, status], 0) }
              "| #{kind} | #{decider} | #{confidence || "—"} | #{counts.join(" | ")} | #{applied.fetch([kind, decider, confidence], 0)} |"
            end + [""]
        end

        def ai_calls
          editions = replay_rows.select(:goodreads_edition_id)
          calls = ::MatchDecision.where(subject_type: "Books::GoodreadsEdition", subject_id: editions).where.not(ai_chat_id: nil).count
          ["## AI calls", "", "Matching AI calls on replay editions: #{calls}", ""]
        end

        def replay_rows
          ::Books::GoodreadsImportRow.joins(:import).merge(::Books::GoodreadsImport.legacy_replay).where.not(goodreads_edition_id: nil)
        end
      end
    end
  end
end
