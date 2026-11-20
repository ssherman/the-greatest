require "test_helper"

module Services
  module Books
    module Profiles
      class TasteTest < ActiveSupport::TestCase
        setup do
          @user = users(:profile_reader)
          @fiction = categories(:books_fiction_genre)
          @novels = categories(:books_novels_genre)
          @politics = categories(:books_politics_subject)
          @history = categories(:books_american_history_subject)
        end

        test "not ready below 10 qualifying books and reports the count" do
          stub_interactions(build_interactions(:read, 9) + build_interactions(:want_to_read, 5))
          Recommendations::ProfileBuilder.expects(:call).never

          data = Taste.call(user: @user)

          assert_equal [false, 9, [], []], [data.ready, data.qualifying_count, data.genres, data.subjects]
        end

        test "reading and want_to_read do not count; favorite, read and rated-only do" do
          stub_interactions(
            build_interactions(:reading, 3) + build_interactions(:want_to_read, 3) +
            build_interactions(:favorite, 2) + build_interactions(:read, 2) + build_interactions(:review, 1, rating: 4)
          )
          Recommendations::ProfileBuilder.expects(:call).never

          assert_equal 5, Taste.call(user: @user).qualifying_count
        end

        test "ready returns genres scaled to the strongest and subjects strongest first" do
          stub_interactions(build_interactions(:read, 10))
          Recommendations::ProfileBuilder.stubs(:call).returns(build_profile(genres: [[@fiction.id, 2.0], [@novels.id, 1.0]], subjects: [[@politics.id, 3.0], [@history.id, 1.0]]))

          data = Taste.call(user: @user)

          assert data.ready
          assert_equal 10, data.qualifying_count
          assert_equal [[@fiction, 1.0], [@novels, 0.5]], data.genres
          assert_equal [@politics, @history], data.subjects
        end

        test "caps genres at 5 and subjects at 8" do
          stub_interactions(build_interactions(:read, 10))
          ids = Array.new(9) { |i| ::Books::Category.create!(name: "Cap #{i}", category_type: :genre).id }
          Recommendations::ProfileBuilder.stubs(:call).returns(build_profile(genres: ids.map { |id| [id, 1.0] }, subjects: ids.map { |id| [id, 1.0] }))

          data = Taste.call(user: @user)

          assert_equal [5, 8], [data.genres.size, data.subjects.size]
        end

        test "ready is false when the profile has no genres and no subjects" do
          stub_interactions(build_interactions(:read, 12))
          Recommendations::ProfileBuilder.stubs(:call).returns(build_profile(genres: [], subjects: []))

          data = Taste.call(user: @user)

          assert_equal [false, 12, [], []], [data.ready, data.qualifying_count, data.genres, data.subjects]
        end

        test "a category id that no longer exists is dropped" do
          stub_interactions(build_interactions(:read, 10))
          Recommendations::ProfileBuilder.stubs(:call).returns(build_profile(genres: [[0, 2.0], [@novels.id, 1.0]], subjects: [[0, 1.0]]))

          data = Taste.call(user: @user)

          assert_equal [[@novels, 1.0]], data.genres
          assert_equal [], data.subjects
        end

        test "a soft-deleted category is dropped from genres and subjects" do
          stub_interactions(build_interactions(:read, 10))
          @novels.update_column(:deleted, true)
          @history.update_column(:deleted, true)
          Recommendations::ProfileBuilder.stubs(:call).returns(build_profile(genres: [[@fiction.id, 2.0], [@novels.id, 1.0]], subjects: [[@politics.id, 3.0], [@history.id, 1.0]]))

          data = Taste.call(user: @user)

          assert_equal [[@fiction, 1.0]], data.genres
          assert_equal [@politics], data.subjects
        end

        private

        def stub_interactions(list)
          Recommendations::Books::Adapter.any_instance.stubs(:interactions).returns(list)
          Recommendations::Books::Adapter.any_instance.stubs(:categories_for).returns({})
        end

        def build_interactions(kind, count, rating: nil)
          Array.new(count) { |i| Recommendations::Interaction.new(item_id: i + 1, weight: 1.0, kind: kind, rating: rating) }
        end

        def build_profile(genres:, subjects:)
          Recommendations::Profile.new(genres: genres, subjects: subjects, locations: [], demoted: [],
            fiction_share: nil, genre_distribution: {}, counts: {})
        end
      end
    end
  end
end
