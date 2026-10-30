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
          lines.join("\n")
        end

        def sample(scope) = scope.order(Arel.sql("random()")).limit(SAMPLE)

        def merges(lines, scope)
          lines << "" << "merges (sample of #{SAMPLE}):"
          sample(scope).each do |verdict|
            source = ::Books::Book.find_by(id: verdict.payload["source_id"])
            target = ::Books::Book.find_by(id: verdict.payload["target_id"])
            lines << %(  book ##{verdict.payload["source_id"]} "#{source&.title}" -> ##{verdict.payload["target_id"]} "#{target&.title}" | ) +
              %(export: "#{verdict.payload["full_title"]}")
          end
        end

        def fixes(lines, scope)
          lines << "" << "fixes (sample of #{SAMPLE}):"
          sample(scope).each do |verdict|
            book = ::Books::Book.includes(:authors).find_by(id: verdict.payload["book_id"])
            lines << %(  ##{verdict.payload["book_id"]} "#{book&.title}" by #{book&.authors&.map(&:name)&.join(", ").presence || "nobody"} -> ) +
              %("#{verdict.payload["full_title"]}" by #{Array(verdict.payload["author_names"]).join(", ")})
          end
        end
      end
    end
  end
end
