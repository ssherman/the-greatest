# frozen_string_literal: true

module Services
  module Books
    module GoodreadsRebuild
      # Many recorded fix_identity verdicts only differ from their book in Goodreads' series or
      # edition noise (FixScope says :none). Applying one would reset a right book and rebuild it
      # through enrichment, so they are retired before apply the way RetireLumpVerdicts retires
      # lump verdicts: rejected and superseded, hidden from the admin queue and never applied.
      # A verdict whose apply has started (it recorded a scope or an archive) is never retired: its book may
      # have been reset and renamed by a failed attempt, which would make it look right. Only unapplied,
      # current, proposed or approved rebuild verdicts are looked at. A dry run unless apply.
      class RetireUnneededFixes
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        SAMPLES = 10
        BATCH = 1_000
        REASON = "Already right: only Goodreads series/edition noise differs"

        def self.call(apply: false)
          new(apply: apply).call
        end

        def initialize(apply:)
          @apply = apply
        end

        def call
          counts = Hash.new(0)
          samples = []
          now = Time.current
          candidates.find_in_batches(batch_size: BATCH) do |verdicts|
            books = ::Books::Book.where(id: verdicts.map { |v| book_id(v) }).index_by(&:id)
            surveys = ::Books::RebuildBookSurvey.where(book_id: books.keys).index_by(&:book_id)
            unneeded = verdicts.select do |verdict|
              book = books[book_id(verdict)]
              book && FixScope.call(book: book, survey: surveys[book.id], payload: verdict.payload) == :none
            end
            unneeded.each do |verdict|
              counts[verdict.status] += 1
              samples << %(##{book_id(verdict)} "#{books[book_id(verdict)].title}" → "#{verdict.payload["full_title"]}") if samples.size < SAMPLES
            end
            next unless @apply && unneeded.any?

            ::Books::RepairVerdict.where(id: unneeded.map(&:id)).update_all(status: ::Books::RepairVerdict.statuses[:rejected],
              superseded_at: now, reviewed_at: now, reason: REASON, updated_at: now)
          end
          Result.new(success?: true, data: {counts: counts, samples: samples, applied: @apply}, errors: [])
        end

        private

        def candidates
          ::Books::RepairVerdict.fix_identity.unapplied.current.where(status: [:proposed, :approved])
            .where("subject_key ~ '^rebuild:[0-9]+$'")
            .where("payload->'fix_scope' IS NULL AND payload->'removed' IS NULL")
        end

        # The subject_key is "rebuild:<book id>".
        def book_id(verdict) = verdict.payload["book_id"]
      end
    end
  end
end
