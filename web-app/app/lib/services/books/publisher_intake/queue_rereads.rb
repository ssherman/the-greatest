# frozen_string_literal: true

module Services
  module Books
    module PublisherIntake
      # Puts read listings back to pending when they are due a re-read (publisher
      # intake design §6): last read more than reread_after_days ago, and either
      # the title is held as placeholder or incomplete (a signal does not change
      # when a publisher fills in a title), or the listing has no signal and its
      # title is not yet on sale. queued_at stays nil so the sweep picks them up.
      # Only listings in state read are touched.
      #
      # data: {queued:}
      class QueueRereads
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        DUE = <<~SQL.squish
          (books_publisher_titles.status = :held AND books_publisher_titles.hold_reason IN (:reasons))
          OR (books_publisher_listings.signal IS NULL
              AND (books_publisher_titles.on_sale_on IS NULL OR books_publisher_titles.on_sale_on > :today))
        SQL

        def self.call(source:)
          new(source: source).call
        end

        def initialize(source:)
          @source = source
        end

        def call
          cutoff = ::Books::PublisherIntake.settings.reread_after_days.days.ago
          due = ::Books::PublisherListing.state_read
            .where(source: @source.key).where(read_at: ...cutoff)
            .joins(:publisher_title)
            .where(DUE,
              held: ::Books::PublisherTitle.statuses[:held],
              reasons: ::Books::PublisherTitle.hold_reasons.values_at("placeholder", "incomplete"),
              today: Date.current)

          queued = ::Books::PublisherListing.where(id: due.select(:id))
            .update_all(state: ::Books::PublisherListing.states[:pending], updated_at: Time.current)
          Result.new(success?: true, data: {queued: queued}, errors: [])
        end
      end
    end
  end
end
