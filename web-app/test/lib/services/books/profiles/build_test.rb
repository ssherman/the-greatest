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
          assert_raises(ArgumentError) { Build.call(user: @user, audience: :public) }
        end

        private

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
