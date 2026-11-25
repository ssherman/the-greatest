# frozen_string_literal: true

module Services
  module Books
    module BookSubmissions
      # Plans the lookups for a book a submission just created: the Goodreads
      # and Amazon steps only, on the priority lane, and no author run (the
      # book is enriched in full when an admin approves it).
      #
      # Skipped when lookups are switched off, when the book already has a
      # submission run (a resumed submission asks again), and once the day's
      # runs reach the ceiling. The ceiling counts runs started by a
      # submission with an "only" option over the last 24 hours. Two
      # submissions racing at the ceiling may overshoot it by a few; that is
      # accepted rather than locked against.
      #
      # data[:started] is true with data[:run], or false with data[:reason]
      # (:disabled, :already_started, :ceiling).
      class StartLookups
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        ONLY = %w[goodreads amazon].freeze
        LIMITED_BY = ::Workflows::Books::BookEnrichment::LIMITED_BY

        def self.call(book:)
          new(book).call
        end

        def initialize(book)
          @book = book
        end

        def call
          config = Rails.application.config.x.book_submissions
          return skipped(:disabled) unless config.lookups_enabled
          return skipped(:already_started) if WorkflowRun.exists?(enrichable: @book, initiated_by: LIMITED_BY)
          return skipped(:ceiling) if runs_in_the_last_day >= config.lookup_runs_per_day

          run = ::Workflows::Books::BookEnrichment.start(@book, initiated_by: LIMITED_BY,
            options: {"only" => ONLY, "lane" => ::Workflows::Lanes::PRIORITY})
          Result.new(success?: true, data: {started: true, run: run}, errors: [])
        end

        private

        def runs_in_the_last_day
          WorkflowRun.where(initiated_by: LIMITED_BY).where("created_at >= ?", 24.hours.ago)
            .where("options -> 'only' IS NOT NULL").count
        end

        def skipped(reason)
          Result.new(success?: true, data: {started: false, reason: reason}, errors: [])
        end
      end
    end
  end
end
