# frozen_string_literal: true

module Services
  module Books
    module Verification
      # Spec section 4, books:verify_report: lines of text the rake task prints.
      class Report
        RECENT = 20
        SAMPLE = 10
        ROUTES = RevertSecondChance::ROUTES

        def self.call(client: nil)
          new(client).call
        end

        def initialize(client)
          @client = client
        end

        def call
          lines = ["Book verification pass", "", "Rows by cohort and stage:"]
          rows.group(:cohort, :stage).count.sort_by { |key, _| key.map(&:to_s) }.each do |(cohort, stage), n|
            lines << format("  %-12s %-12s %d", cohort, stage, n)
          end
          lines << ""
          lines << "Work outcomes:"
          counts = rows.group(:work_outcome).count
          ::Books::Verification.work_outcomes.each_key { |outcome| lines << format("  %-15s %d", outcome, counts.fetch(outcome, 0)) }
          lines << ""
          lines << "Settled via route:"
          route_counts = rows.where(lookup: ROUTES).group(:lookup).count
          ROUTES.each { |route| lines << format("  %-18s %d", route, route_counts.fetch(route, 0)) }
          lines << ""
          lines << abstain_line
          lines << ranked_line
          lines << latest_run_line
          lines << latest_failure_line
          lines << latest_stage_error_line
          lines << author_line
          lines << ""
          lines << "Ranked identifiers by type and source:"
          lines.concat(coverage_lines)
          lines << ""
          lines << "Findings:"
          kinds = ::Books::VerificationFinding.group(:kind).count
          ::Books::VerificationFinding.kinds.each_key { |kind| lines << format("  %-18s %d", kind, kinds.fetch(kind, 0)) }
          lines << "Lump suspects: #{rows.where(lump_suspect: true).count}"
          lines << "Edition candidates: #{::Books::EditionCandidate.count}"
          lines << ""
          lines << "Most recent replaced keys and pairs:"
          lines.concat(recent_lines)
          lines << ""
          lines << "Samples:"
          lines.concat(sample_lines)
          lines
        end

        private

        def latest_stage_error_line
          row = rows.where.not(stage_error: [nil, ""]).includes(:book).order(updated_at: :desc, id: :desc).first
          return "Latest stage error: none" unless row

          "Latest stage error: book #{row.book_id} \"#{row.book.title}\" at stage #{row.stage}: #{row.stage_error} at #{row.updated_at.iso8601}"
        end

        def coverage_lines
          config = ::Books::RankingConfiguration.default_primary
          ranked = ::RankedItem.where(ranking_configuration_id: config&.id, item_type: "Books::Book").where.not(rank: nil).select(:item_id)
          counts = ::Identifier.where(identifiable_type: "Books::Book", identifiable_id: ranked).group(:identifier_type, :source).count
          return ["  none"] if counts.empty?

          counts.sort_by { |key, _| key.map(&:to_s) }.map do |(type, source), n|
            format("  %-28s %-16s %d", type, source || "none", n)
          end
        end

        def sample_lines
          lines = []
          ::Books::Verification.work_outcomes.each_key do |outcome|
            sampled = rows.where(work_outcome: outcome).includes(book: :authors).order(Arel.sql("random()")).limit(SAMPLE).to_a
            next if sampled.empty?

            lines << "  #{outcome}:"
            ol = open_library_records(sampled.filter_map { |row| row.new_key.presence })
            sampled.each { |row| lines << "    #{book_label(row.book)}#{outcome_tail(row, ol)}" }
          end
          ROUTES.each do |route|
            ::Books::Verification.work_outcomes.each_key do |outcome|
              sampled = rows.where(lookup: route, work_outcome: outcome).includes(book: :authors).order(Arel.sql("random()")).limit(SAMPLE).to_a
              next if sampled.empty?

              lines << "  via #{route} (#{outcome}):"
              ol = open_library_records(sampled.filter_map { |row| row.new_key.presence })
              sampled.each { |row| lines << "    #{book_label(row.book)}#{outcome_tail(row, ol)}" }
            end
          end
          lines.concat(finding_samples("Open Library trusted writes", ::Books::VerificationFinding.where(source: :open_library, kind: %i[added confirmed])))
          lines.concat(finding_samples("WorldCat confirmations", ::Books::VerificationFinding.confirmed.where(source: :worldcat)))
          lines.concat(finding_samples("Wrong identifiers", ::Books::VerificationFinding.wrong_identifier))
          lines
        end

        def finding_samples(label, scope)
          sampled = scope.includes(book: :authors).order(Arel.sql("random()")).limit(SAMPLE).to_a
          return [] if sampled.empty?

          ["  #{label}:"] + sampled.map { |finding| "    #{book_label(finding.book)} #{finding.value} -> #{evidence_text(finding)}" }
        end

        def book_label(book)
          names = book.authors.map(&:name).join(", ")
          "book #{book.id} \"#{book.title}\" by #{names.presence || "unknown"}"
        end

        def evidence_text(finding)
          evidence = finding.evidence.is_a?(Hash) ? finding.evidence : {}
          if evidence["edition_key"].present? || evidence["title"].present?
            return ["edition #{evidence["edition_key"]}".strip, evidence["title"].presence&.then { |title| "\"#{title}\"" }].compact.join(" ")
          end

          works = Array(evidence["works"])
          return works.first(3).map { |work| [work["key"], work["title"]].compact.join(" ") }.join("; ") if works.any?

          records = Array(evidence["records"])
          return "no evidence" if records.empty?

          records.first(3).map { |record| [record["title"], record["creator"], record["year"]].compact.join(" / ") }.join("; ")
        end

        def outcome_tail(row, ol)
          return "" if row.new_key.blank?

          work = ol[row.new_key]
          detail = work ? " (Open Library: \"#{work.title}\" by #{Array(work.author_names).join(", ").presence || "unknown"})" : ""
          " -> #{row.new_key}#{detail}"
        end

        def open_library_records(keys)
          return {} if @client.nil? || keys.empty?

          @client.works_batch(keys.first(::Books::OpenLibrary::Client::MAX_BATCH))
        rescue ::Books::OpenLibrary::Exceptions::Error
          {}
        end

        def rows = ::Books::Verification.all

        def ranked_line
          config = ::Books::RankingConfiguration.default_primary
          ranked = ::RankedItem.where(ranking_configuration_id: config&.id, item_type: "Books::Book").where.not(rank: nil)
          checked = rows.where(book_id: ranked.select(:item_id)).where.not(work_outcome: :failed).count
          "Ranked books checked: #{checked} of #{ranked.count}"
        end

        def latest_run_line
          latest = rows.order(updated_at: :desc, id: :desc).first
          return "Latest run: none" unless latest

          "Latest run #{latest.run_id}: #{rows.where(run_id: latest.run_id).count} books, last at #{latest.updated_at.iso8601}"
        end

        def abstain_line
          "Confirmed on Open Library's top answer (abstained): #{rows.where(confirmed_on_abstain: true).count}"
        end

        def latest_failure_line
          failure = rows.failed.includes(:book).order(updated_at: :desc, id: :desc).first
          return "Latest failure: none" unless failure

          "Latest failure: book #{failure.book_id} \"#{failure.book.title}\": #{failure.error} at #{failure.updated_at.iso8601}"
        end

        def author_line
          totals = %w[added pairs conflicts].map do |part|
            rows.sum(Arel.sql("jsonb_array_length(COALESCE(author_changes->'#{part}', '[]'::jsonb))")).to_i
          end
          format("Author keys added: %d, author pairs: %d, author conflicts: %d", *totals)
        end

        def recent_lines
          pairs = rows.where(work_outcome: :confirmed).where.not(pair_book_id: nil)
          recent = rows.where(work_outcome: %i[replaced duplicate_pair removed]).or(pairs).includes(:book).order(updated_at: :desc, id: :desc).limit(RECENT)
          return ["  none"] if recent.empty?

          recent.map do |row|
            keys = (row.work_outcome == "removed") ? row.old_keys - row.book.identifiers.where(identifier_type: ApplyBook::WORK_KEY).pluck(:value) : row.old_keys
            pair = row.pair_book_id ? " (pair with book #{row.pair_book_id})" : ""
            "  #{row.work_outcome} book #{row.book_id} \"#{row.book.title}\": #{keys.join(", ").presence || "no key"} -> #{row.new_key.presence || "no key"}#{pair}"
          end
        end
      end
    end
  end
end
