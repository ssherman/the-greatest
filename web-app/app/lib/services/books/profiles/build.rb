module Services
  module Books
    module Profiles
      # Assembles everything a books profile page renders into one object.
      # Owner audience: every section is built, not limited to the public
      # catalog, and the recommendations card is included. Public audience:
      # catalog only, and only the sections the profile's switches allow.
      class Build
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        Header = Struct.new(:name, :member_since_year, keyword_init: true)
        Data = Struct.new(:audience, :header, :stats, :favorites, :goals, :reading_now, :taste,
          :recently_read, :top_rated, :recent_reviews, :recommendations, keyword_init: true) do
          # The shelf list and the goal stay on the structs for every audience;
          # the public page may only link to them when they are public too.
          def linkable?(record)
            audience == :owner || !!record&.public?
          end
        end

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
          case @audience
          when :owner then owner_data
          when :public then public_data
          else raise ArgumentError, "unknown audience: #{@audience.inspect}"
          end
        end

        private

        def owner_data
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

        # Privacy boundary: a section is computed only when its switch is on,
        # so a switched-off section never touches the database (or the taste
        # cache). Sections that are on but empty come back nil.
        def public_data
          raise ArgumentError, "profile is required for the public audience" if @profile.nil?

          library = Library.new(user: @user, catalog_only: true, today: @today)
          data = Data.new(
            audience: :public,
            header: Header.new(name: @profile.display_name.presence, member_since_year: @user.created_at.year),
            stats: section(:stats) { library.stats }&.then { |stats| stats unless stats.to_a.all?(&:nil?) },
            favorites: shelf(:favorites) { library.favorites },
            goals: section(:goals) { library.goals }.presence,
            reading_now: shelf(:reading_now) { library.reading_now },
            taste: section(:taste) { taste }&.then { |taste_data| taste_data if taste_data.ready },
            recently_read: shelf(:recently_read) { library.recently_read },
            top_rated: section(:top_rated) { library.top_rated }.presence,
            recent_reviews: section(:reviews) { library.recent_reviews }.presence,
            recommendations: nil
          )
          Result.new(success?: true, data: data, errors: [])
        end

        def section(name)
          yield if @profile.show?(name)
        end

        def shelf(name)
          shelf = section(name) { yield }
          shelf if shelf&.books&.any?
        end

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
