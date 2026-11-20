require "test_helper"

module Services
  module Books
    module Profiles
      class BuildTest < ActiveSupport::TestCase
        setup do
          @user = users(:profile_reader)
          Recommended.stubs(:call).returns(Recommended::Data.new(state: :no_history, books: []))
        end

        test "owner data has every section and the header name from users.display_name" do
          result = Build.call(user: @user, audience: :owner)

          assert result.success?
          data = result.data
          assert_equal :owner, data.audience
          assert_equal "Profile Reader", data.header.name
          %i[stats favorites goals reading_now taste recently_read top_rated recent_reviews recommendations].each do |section|
            assert_not_nil data.public_send(section), section.to_s
          end
          assert_equal :no_history, data.recommendations.state
        end

        test "owner header name is nil when the user has no display name" do
          @user.update_column(:display_name, nil)

          assert_nil Build.call(user: @user, audience: :owner).data.header.name
        end

        test "member_since_year is the year of users.created_at" do
          assert_equal @user.created_at.year, Build.call(user: @user, audience: :owner).data.header.member_since_year
        end

        test "an empty account builds successfully with empty sections" do
          result = Build.call(user: users(:profile_empty_reader), audience: :owner)

          assert result.success?
          assert_equal false, result.data.taste.ready
          assert_equal 0, result.data.favorites.total
        end

        test "a ready taste is cached per user, so a second build does not recompute it" do
          with_memory_cache do
            other = users(:profile_empty_reader)
            ready = Taste::Data.new(ready: true, qualifying_count: 12, genres: [], subjects: [])
            Taste.expects(:call).with(user: @user).once.returns(ready)
            Taste.expects(:call).with(user: other).once.returns(ready)

            2.times { Build.call(user: @user, audience: :owner) }
            Build.call(user: other, audience: :owner)
          end
        end

        test "a not-ready taste is recomputed on the next build" do
          with_memory_cache do
            Taste.expects(:call).with(user: @user).twice
              .returns(Taste::Data.new(ready: false, qualifying_count: 9, genres: [], subjects: []))

            2.times { Build.call(user: @user, audience: :owner) }
          end
        end

        test "an unknown audience raises ArgumentError" do
          assert_raises(ArgumentError) { Build.call(user: @user, audience: :admin) }
        end

        test "public requires a profile" do
          assert_raises(ArgumentError) { Build.call(user: @user, audience: :public) }
        end

        test "a switched-off section is nil and is never queried" do
          profile = books_profiles(:public_profile)
          profile.update!(show_stats: false, show_goals: false, show_reading_now: false, show_taste: false,
            show_recently_read: false, show_top_rated: false, show_reviews: false)
          add_favorite(@user, books_books(:war_and_peace))
          Library.any_instance.expects(:stats).never
          Library.any_instance.expects(:goals).never
          Library.any_instance.expects(:reading_now).never
          Library.any_instance.expects(:recently_read).never
          Library.any_instance.expects(:top_rated).never
          Library.any_instance.expects(:recent_reviews).never
          Taste.expects(:call).never

          data = Build.call(user: @user, audience: :public, profile: profile).data

          assert_equal [books_books(:war_and_peace).id], data.favorites.books.map(&:id)
          %i[stats goals reading_now taste recently_read top_rated recent_reviews].each do |section|
            assert_nil data.public_send(section), section.to_s
          end
        end

        test "a switched-off favorites section is never queried" do
          profile = books_profiles(:public_profile)
          profile.update!(show_favorites: false)
          Library.any_instance.expects(:favorites).never

          assert_nil Build.call(user: @user, audience: :public, profile: profile).data.favorites
        end

        test "a switched-on but empty section is nil" do
          user = users(:profile_empty_reader)
          profile = books_profiles(:private_profile)
          profile.update!(show_stats: true, show_favorites: true, show_goals: true, show_reading_now: true,
            show_taste: true, show_recently_read: true, show_top_rated: true, show_reviews: true)

          data = Build.call(user: user, audience: :public, profile: profile).data

          %i[stats favorites goals reading_now taste recently_read top_rated recent_reviews].each do |section|
            assert_nil data.public_send(section), section.to_s
          end
        end

        test "public never builds recommendations" do
          Recommended.expects(:call).never

          data = Build.call(user: @user, audience: :public, profile: books_profiles(:public_profile)).data

          assert_nil data.recommendations
          assert_equal :public, data.audience
        end

        test "public uses catalog-only data" do
          hidden = books_books(:war_and_peace)
          shown = books_books(:crime_and_punishment)
          [hidden, shown].each { |book| add_favorite(@user, book) }
          [hidden, shown].each { |book| add_to(@user, :read, book) }
          hidden.update_column(:provisional, true)

          data = Build.call(user: @user, audience: :public, profile: books_profiles(:public_profile)).data

          assert_equal [shown.id], data.favorites.books.map(&:id)
          assert_equal 1, data.stats.books_read
        end

        test "public header uses the profile display name, not the account one" do
          profile = books_profiles(:public_profile)

          assert_equal "Avid Reader", Build.call(user: @user, audience: :public, profile: profile).data.header.name

          profile.update_column(:display_name, "")
          assert_nil Build.call(user: @user, audience: :public, profile: profile).data.header.name
        end

        test "a ready taste is shown publicly only when its switch is on, from the shared cache" do
          with_memory_cache do
            ready = Taste::Data.new(ready: true, qualifying_count: 12, genres: [], subjects: [])
            Taste.expects(:call).with(user: @user).once.returns(ready)
            Build.call(user: @user, audience: :owner)

            data = Build.call(user: @user, audience: :public, profile: books_profiles(:public_profile)).data

            assert_equal [true, 12], [data.taste.ready, data.taste.qualifying_count]
          end
        end

        test "linkable? is true for the owner, and for public only when the list or goal is public" do
          owner = Build.call(user: @user, audience: :owner).data
          visitor = Build.call(user: @user, audience: :public, profile: books_profiles(:public_profile)).data
          private_list = ::Books::UserList.new(public: false)
          public_list = ::Books::UserList.new(public: true)
          public_goal = ::Books::ReadingGoal.new(public: true)

          assert owner.linkable?(private_list)
          assert visitor.linkable?(public_list)
          assert visitor.linkable?(public_goal)
          assert_not visitor.linkable?(private_list)
          assert_not visitor.linkable?(nil)
        end

        test "with every switch off the data is the header alone" do
          profile = books_profiles(:public_profile)
          profile.update!(show_stats: false, show_favorites: false, show_goals: false, show_reading_now: false,
            show_taste: false, show_recently_read: false, show_top_rated: false, show_reviews: false)

          data = Build.call(user: @user, audience: :public, profile: profile).data

          assert_equal "Avid Reader", data.header.name
          assert_equal [nil] * 9, data.to_h.except(:audience, :header).values
        end

        private

        def add_favorite(user, book)
          add_to(user, :favorites, book)
        end

        def add_to(user, type, book)
          list = ::Books::UserList.find_by(user: user, list_type: type) ||
            ::Books::UserList.create!(user: user, list_type: type, name: ::Books::UserList.default_list_name_for(type))
          list.user_list_items.create!(listable: book)
        end

        def with_memory_cache
          original = Rails.cache
          Rails.cache = ActiveSupport::Cache::MemoryStore.new
          yield
        ensure
          Rails.cache = original
        end
      end
    end
  end
end
