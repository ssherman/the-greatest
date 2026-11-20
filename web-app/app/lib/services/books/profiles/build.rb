module Services
  module Books
    module Profiles
      # Assembles everything a books profile page renders into one object.
      # Owner audience only for now: every section is built, not limited to
      # the public catalog, and the recommendations card is included.
      class Build
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        Header = Struct.new(:name, :member_since_year, keyword_init: true)
        Data = Struct.new(:audience, :header, :stats, :favorites, :goals, :reading_now, :taste,
          :recently_read, :top_rated, :recent_reviews, :recommendations, keyword_init: true)

        def self.call(user:, audience:, profile: nil, today: Date.current)
          new(user: user, audience: audience, profile: profile, today: today).call
        end

        def initialize(user:, audience:, profile:, today:)
          @user = user
          @audience = audience
          @profile = profile
          @today = today
        end

        def call
          raise ArgumentError, "unknown audience: #{@audience.inspect}" unless @audience == :owner

          library = Library.new(user: @user, catalog_only: false, today: @today)
          data = Data.new(
            audience: :owner,
            header: Header.new(name: @user.display_name.presence, member_since_year: @user.created_at.year),
            stats: library.stats,
            favorites: library.favorites,
            goals: library.goals,
            reading_now: library.reading_now,
            taste: taste,
            recently_read: library.recently_read,
            top_rated: library.top_rated,
            recent_reviews: library.recent_reviews,
            recommendations: Recommended.call(user: @user)
          )
          Result.new(success?: true, data: data, errors: [])
        end

        private

        # Measured at 0.5-1.1s for the heaviest reader (24k read books), which
        # alone breaks the one-second budget; taste moves slowly, so an hour
        # of staleness is fine.
        #
        # Only ready results are cached: a not-ready result is the cheap path,
        # and caching it would show a stale "N of 10" count after the reader
        # finishes another book.
        def taste
          key = ["books-profile-taste", @user.id]
          cached = Rails.cache.read(key)
          return cached if cached

          Taste.call(user: @user).tap do |data|
            Rails.cache.write(key, data, expires_in: 1.hour) if data.ready
          end
        end
      end
    end
  end
end
