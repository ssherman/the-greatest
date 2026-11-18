# frozen_string_literal: true

module Services
  module Books
    module PublisherIntake
      # Moves up to limit of a source's baseline listings to pending, highest
      # external_key first, so the daily reader starts on them. Other sources
      # and other states are untouched; a missing or non-positive limit
      # releases nothing.
      #
      # data: {released: n}
      class ReleaseBaseline
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(source:, limit:)
          new(source: source, limit: limit).call
        end

        def initialize(source:, limit:)
          @source = source
          @limit = limit.to_i
        end

        def call
          return result(0) unless @limit.positive?

          ids = ::Books::PublisherListing.where(source: @source, state: :baseline)
            .order(external_key: :desc, id: :desc).limit(@limit).pluck(:id)
          released = ::Books::PublisherListing.where(id: ids, state: :baseline).update_all(state: ::Books::PublisherListing.states[:pending],
            updated_at: Time.current)
          result(released)
        end

        private

        def result(count) = Result.new(success?: true, data: {released: count}, errors: [])
      end
    end
  end
end
