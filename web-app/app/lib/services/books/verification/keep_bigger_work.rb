# frozen_string_literal: true

module Services
  module Books
    module Verification
      # books:verify_keep_bigger. Before Lookup#keep_bigger_held, Open Library's
      # matcher could move a book off a work it held that passes our check onto
      # one with fewer editions, and stage 2 then harvested only the small one
      # (production, 2026-10-26: 219 books on the first pass, 59 on the second
      # chance; Ethics 75 editions to 1). This finds those books by their rows'
      # old and prior keys and, with apply, reverts each and queues one redo run
      # over them, which settles them again under the current rules.
      #
      # A book the redo settles on the small work again (the bigger one was a
      # conflicted /resolve candidate) is found again by a later run.
      class KeepBiggerWork
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        SETTLED = (::Books::Verification::KEYED_OUTCOMES + %w[duplicate_pair]).freeze
        # The redo names its books; these let it take any cohort and unranked ones.
        REDO_FLAGS = %w[redo unranked post_import].freeze
        FETCH_SLICE = 50
        SAMPLE_LIMIT = 20

        def self.call(apply: false, client: ::Books::OpenLibrary::Client.new)
          new(apply: apply, client: client).call
        end

        def initialize(apply:, client:)
          @apply = apply
          @client = client
        end

        def call
          rows = ::Books::Verification.where(work_outcome: SETTLED).where.not(new_key: nil).includes(book: :authors).order(:book_id).to_a
          works = fetch_works(rows.flat_map { |row| old_keys(row) + [row.new_key] }.uniq)
          found = rows.filter_map { |row| (bigger = bigger_work(row, works)) && [row, bigger] }

          data = {found: found.size, reverted: 0, failed: [], run_id: nil,
                  samples: found.first(SAMPLE_LIMIT).map { |row, bigger| sample(row, works[row.new_key], bigger) }}
          revert_and_queue(found.map(&:first), data) if @apply && found.any?
          Result.new(success?: true, data: data, errors: [])
        end

        private

        def old_keys(row) = (row.old_keys + row.prior_keys).uniq - [row.new_key]

        # The held work with the most editions, more than the settled one, that
        # passes our check. Editions first: our check can fetch author records.
        def bigger_work(row, works)
          editions = edition_count(works[row.new_key])
          old_keys(row).filter_map { |key| works[key] }
            .reject { |work| work.key == row.new_key }
            .select { |work| edition_count(work) > editions }
            .sort_by { |work| -edition_count(work) }
            .find { |work| Check.verified?(row.book, work, @client) }
        end

        def edition_count(work) = work&.popularity&.dig(:edition_count).to_i

        def fetch_works(keys)
          keys.each_slice([FETCH_SLICE, ::Books::OpenLibrary::Client::MAX_BATCH].min).each_with_object({}) do |slice, works|
            works.merge!(@client.works_batch(slice))
          end
        end

        # A row a second chance settled goes back to before the second chance;
        # any other goes back to before the pass (reverted, which the redo takes).
        def revert_and_queue(rows, data)
          ids = rows.filter_map do |row|
            result = RevertSecondChance.applies_to?(row) ? RevertSecondChance.call(book: row.book) : Revert.call(book: row.book)
            next row.book_id if result.success?

            data[:failed] << "book #{row.book_id}: #{result.errors.join("; ")}"
            nil
          end
          return if ids.empty?

          data[:reverted] = ids.size
          data[:run_id] = SecureRandom.uuid
          ::Books::VerificationJob.perform_async(nil, data[:run_id], REDO_FLAGS, ids)
        end

        def sample(row, settled, bigger)
          "book #{row.book_id} #{row.book.title.inspect}: #{row.new_key} #{settled&.title.inspect} (#{edition_count(settled)} editions) " \
            "-> #{bigger.key} #{bigger.title.inspect} (#{edition_count(bigger)} editions)"
        end
      end
    end
  end
end
