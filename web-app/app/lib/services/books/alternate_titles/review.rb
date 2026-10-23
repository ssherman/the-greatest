# frozen_string_literal: true

module Services
  module Books
    module AlternateTitles
      # Has the AI judge every unjudged alternate title of one book and applies
      # the verdicts (spec 2026-10-23, Part 2, "What a verdict does"). Every AI
      # call runs before anything is written, so a failed call leaves the book
      # untouched; the rows and the book's array copy then change in one
      # transaction.
      class Review
        CHUNK = 40

        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(book:)
          new(book).call
        end

        def initialize(book)
          @book = book
        end

        def call
          Services::AlternateTitles::Backfill.call(@book)
          rows = ::AlternateTitle.where(titleable: @book).unjudged.order(:id).to_a
          return success(counts) if rows.empty?

          accepted = ::AlternateTitle.where(titleable: @book).where(status: :kept).where.not(verdict: nil).order(:id).pluck(:title)
          verdicts = {}
          rows.each_slice(CHUNK) do |chunk|
            failure = judge(chunk, accepted, verdicts)
            return failure if failure
          end
          missing = rows.reject { |row| verdicts.key?(row.id) }
          # One more try for what a call left out.
          if missing.any?
            failure = judge(missing, accepted, verdicts)
            return failure if failure
            missing = rows.reject { |row| verdicts.key?(row.id) }
          end

          write(rows, verdicts, missing.size)
        end

        private

        # Returns a failure Result, or nil after adding the chunk's verdicts.
        def judge(chunk, accepted, verdicts)
          entries = chunk.each_with_index.map do |row, i|
            Services::Ai::Tasks::Books::AlternateTitlesReviewTask::Entry.new(key: (i + 1).to_s, title: row.title)
          end
          outcome = Services::Ai::Tasks::Books::AlternateTitlesReviewTask.new(
            parent: @book, entries: entries, accepted: accepted
          ).call
          return failure(outcome.error) unless outcome.success?

          outcome.data[:results].each do |key, result|
            row = chunk[key.to_i - 1]
            verdicts[row.id] = result.merge(ai_chat: outcome.ai_chat) if row
          end
          nil
        end

        def write(rows, verdicts, missing)
          counts = counts(missing: missing)
          threshold = Rails.configuration.x.books_alternate_titles.auto_remove_confidence
          now = Time.current
          ::AlternateTitle.transaction do
            rows.each do |row|
              result = verdicts[row.id] or next
              attrs = {verdict: result[:verdict], category: result[:category], confidence: result[:confidence],
                       reason: result[:reason], ai_chat: result[:ai_chat], judged_at: now}
              if result[:verdict] == "same_work"
                attrs[:decided_by] = :ai
                attrs[:decided_at] = now
                counts[:kept] += 1
              elsif result[:confidence] >= threshold && !row.from_admin?
                attrs.merge!(status: :removed, decided_by: :ai, decided_at: now)
                counts[:removed] += 1
              else
                attrs[:status] = :review
                counts[:review] += 1
              end
              row.update!(attrs)
              counts[:judged] += 1
            end

            listed = Services::AlternateTitles::Writer.listed_titles(@book)
            if @book.alternate_titles != listed
              @book.alternate_titles = listed
              @book.save!
            end
          end
          success(counts)
        end

        def counts(missing: 0) = {judged: 0, kept: 0, removed: 0, review: 0, missing: missing}

        def success(data) = Result.new(success?: true, data: data, errors: [])

        def failure(message) = Result.new(success?: false, data: nil, errors: [message])
      end
    end
  end
end
