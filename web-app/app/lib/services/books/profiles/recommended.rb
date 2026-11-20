module Services
  module Books
    module Profiles
      # The recommendations card on a reader's own profile: the first few
      # books from the same engine call the recommendations page makes, with
      # the reader's stored settings. Never raises; a failure is :unavailable.
      class Recommended
        LIMIT = 6

        # state: :ok | :no_history | :unavailable
        Data = Struct.new(:state, :books, keyword_init: true)

        def self.call(user:)
          new(user: user).call
        end

        def initialize(user:)
          @user = user
        end

        def call
          return Data.new(state: :no_history, books: []) unless ::Recommendations::Books::Pages.new(user: @user).history?

          result = ::Recommendations::Engine.call(user: @user, domain: "books", limit: LIMIT, overrides: overrides)
          books = result.success? ? result.data[:items].map { |entry| entry[:item] } : []
          return Data.new(state: :unavailable, books: []) if books.empty?

          Data.new(state: :ok, books: books)
        rescue => e
          Rails.logger.error("Books profile recommendations failed for user #{@user.id}: #{e.class}: #{e.message}")
          Data.new(state: :unavailable, books: [])
        end

        private

        def overrides
          ::RecommendationConfig.subclass_for("books").for_user(@user).criteria_object.engine_overrides
        end
      end
    end
  end
end
