# frozen_string_literal: true

module Services
  module Books
    module GoodreadsRebuild
      # DecideFix now leaves lump records alone (a lump holds Goodreads rows of
      # several different books, and deciding it from its biggest group would
      # move every reader onto that one book). The first production runs had
      # already recorded some lump verdicts; this retires the unapplied ones the
      # way RetireReplayProposals does: rejected and superseded, so the admin
      # queue hides them and nothing can apply them. A verdict already applied
      # to a lump is never touched; it is only counted so it can be looked at.
      # A dry run unless apply.
      class RetireLumpVerdicts
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        KINDS = %w[fix_identity merge_books].freeze
        SAMPLES = 10
        REASON = "Lump record: left for the split step"

        def self.call(apply: false)
          new(apply: apply).call
        end

        def initialize(apply:)
          @apply = apply
        end

        def call
          # unapplied: a verdict already applied to a lump stays as it is. Rejected ones (an admin's call) stay too;
          # approved ones are retired because an auto-approved verdict would otherwise be applied.
          scope = lump_verdicts.unapplied.current.where(status: [:proposed, :approved])
          counts = scope.group(:kind, :status).count.transform_keys { |kind, status| "#{kind} #{status}" }
          samples = sample_lines(scope)
          if @apply
            now = Time.current
            scope.update_all(status: ::Books::RepairVerdict.statuses[:rejected], superseded_at: now, reviewed_at: now, reason: REASON, updated_at: now)
          end
          gone = applied_survey_gone
          Result.new(success?: true, data: {counts: counts, already_applied: lump_verdicts.where.not(applied_at: nil).count, samples: samples,
                                            applied_unknown: gone.count, applied_unknown_keys: gone.order(:id).limit(SAMPLES).pluck(:subject_key),
                                            applied: @apply}, errors: [])
        end

        private

        # An applied merge destroys its source book and the survey cascades with it, so lump_verdicts
        # cannot see it. These are reported, never touched: they may have been lump merges.
        def applied_survey_gone
          surveyed = ::Books::RebuildBookSurvey.select(:book_id)
          ::Books::RepairVerdict.where(kind: KINDS).where.not(applied_at: nil)
            .where("CAST(NULLIF(substring(subject_key FROM '^rebuild:([0-9]+)$'), '') AS bigint) NOT IN (?)", surveyed)
            .where("subject_key ~ '^rebuild:[0-9]+$'")
        end

        # The subject_key is "rebuild:<book id>" for both kinds, so the book id comes from it.
        def lump_verdicts
          lumps = ::Books::RebuildBookSurvey.lump.select(:book_id)
          ::Books::RepairVerdict.where(kind: KINDS)
            .where("CAST(NULLIF(substring(subject_key FROM '^rebuild:([0-9]+)$'), '') AS bigint) IN (?)", lumps)
        end

        def sample_lines(scope)
          scope.order(:id).limit(SAMPLES).filter_map do |verdict|
            id = verdict.subject_key.delete_prefix("rebuild:").to_i
            survey = ::Books::RebuildBookSurvey.find_by(book_id: id)
            next unless survey

            groups = survey.groups.map { |g| "\"#{Array(g["titles"]).first}\" (#{g["row_count"]})" }.join(" | ")
            "##{id} \"#{survey.book.title}\": groups #{groups}"
          end
        end
      end
    end
  end
end
