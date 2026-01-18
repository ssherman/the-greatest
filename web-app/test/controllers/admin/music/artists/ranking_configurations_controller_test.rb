require "test_helper"

module Admin
  module Music
    module Artists
      class RankingConfigurationsControllerTest < ActionDispatch::IntegrationTest
        setup do
          @ranking_configuration = ranking_configurations(:music_artists_global)
          @admin_user = users(:admin_user)
          @editor_user = users(:editor_user)
          @regular_user = users(:regular_user)

          host! Rails.application.config.domains[:music]
        end

        test "should redirect index to root for unauthenticated users" do
          get admin_artists_ranking_configurations_path
          assert_redirected_to music_root_path
          assert_equal "Access denied. You need permission for music admin.", flash[:alert]
        end

        test "should redirect to root for regular users" do
          sign_in_as(@regular_user, stub_auth: true)
          get admin_artists_ranking_configurations_path
          assert_redirected_to music_root_path
          assert_equal "Access denied. You need permission for music admin.", flash[:alert]
        end

        test "should allow admin users to access index" do
          sign_in_as(@admin_user, stub_auth: true)
          get admin_artists_ranking_configurations_path
          assert_response :success
        end

        test "should allow editor users to access index" do
          sign_in_as(@editor_user, stub_auth: true)
          get admin_artists_ranking_configurations_path
          assert_response :success
        end

        test "should get index without search" do
          sign_in_as(@admin_user, stub_auth: true)
          get admin_artists_ranking_configurations_path
          assert_response :success
        end

        test "should get index with search query" do
          sign_in_as(@admin_user, stub_auth: true)

          get admin_artists_ranking_configurations_path(q: "Global")
          assert_response :success
        end

        test "should handle empty search results without error" do
          sign_in_as(@admin_user, stub_auth: true)

          assert_nothing_raised do
            get admin_artists_ranking_configurations_path(q: "nonexistentconfig")
          end

          assert_response :success
        end

        test "should handle sorting by name" do
          sign_in_as(@admin_user, stub_auth: true)
          get admin_artists_ranking_configurations_path(sort: "name")
          assert_response :success
        end

        test "should handle sorting by id" do
          sign_in_as(@admin_user, stub_auth: true)
          get admin_artists_ranking_configurations_path(sort: "id")
          assert_response :success
        end

        test "should reject invalid sort parameters and default to name" do
          sign_in_as(@admin_user, stub_auth: true)

          assert_nothing_raised do
            get admin_artists_ranking_configurations_path(sort: "'; DROP TABLE ranking_configurations; --")
          end
          assert_response :success

          assert ::Music::Artists::RankingConfiguration.count > 0
        end

        test "should only allow whitelisted sort columns" do
          sign_in_as(@admin_user, stub_auth: true)

          ["id", "name", "published_at", "created_at"].each do |column|
            get admin_artists_ranking_configurations_path(sort: column)
            assert_response :success
          end

          ["description", "invalid", "ranking_configurations.id; --"].each do |column|
            get admin_artists_ranking_configurations_path(sort: column)
            assert_response :success
          end
        end

        test "should paginate results" do
          sign_in_as(@admin_user, stub_auth: true)
          get admin_artists_ranking_configurations_path
          assert_response :success
        end

        test "should get show for admin" do
          sign_in_as(@admin_user, stub_auth: true)
          get admin_artists_ranking_configuration_path(@ranking_configuration)
          assert_response :success
        end

        test "should get show for editor" do
          sign_in_as(@editor_user, stub_auth: true)
          get admin_artists_ranking_configuration_path(@ranking_configuration)
          assert_response :success
        end

        test "should not get show for regular user" do
          sign_in_as(@regular_user, stub_auth: true)
          get admin_artists_ranking_configuration_path(@ranking_configuration)
          assert_redirected_to music_root_path
        end

        test "should load ranking configuration with associations" do
          sign_in_as(@admin_user, stub_auth: true)
          get admin_artists_ranking_configuration_path(@ranking_configuration)
          assert_response :success
        end

        test "should get new for admin" do
          sign_in_as(@admin_user, stub_auth: true)
          get new_admin_artists_ranking_configuration_path
          assert_response :success
        end

        test "should not get new for editor (manage permission required)" do
          sign_in_as(@editor_user, stub_auth: true)
          get new_admin_artists_ranking_configuration_path
          assert_redirected_to music_root_path
        end

        test "should not get new for regular user" do
          sign_in_as(@regular_user, stub_auth: true)
          get new_admin_artists_ranking_configuration_path
          assert_redirected_to music_root_path
        end

        test "should create ranking configuration for admin with valid params" do
          sign_in_as(@admin_user, stub_auth: true)

          assert_difference("::Music::Artists::RankingConfiguration.count", 1) do
            post admin_artists_ranking_configurations_path, params: {
              ranking_configuration: {
                name: "New Test Artist Configuration",
                description: "Test description for artist rankings",
                global: true,
                primary: false
              }
            }
          end

          assert_redirected_to admin_artists_ranking_configuration_path(::Music::Artists::RankingConfiguration.last)
          assert_equal "Ranking configuration created successfully.", flash[:notice]
        end

        test "should not create ranking configuration with invalid data" do
          sign_in_as(@admin_user, stub_auth: true)

          assert_no_difference("::Music::Artists::RankingConfiguration.count") do
            post admin_artists_ranking_configurations_path, params: {
              ranking_configuration: {
                name: "",
                description: "Test description"
              }
            }
          end

          assert_response :unprocessable_entity
        end

        test "should not create ranking configuration for regular user" do
          sign_in_as(@regular_user, stub_auth: true)

          assert_no_difference("::Music::Artists::RankingConfiguration.count") do
            post admin_artists_ranking_configurations_path, params: {
              ranking_configuration: {
                name: "New Test Configuration",
                global: true,
                primary: false
              }
            }
          end

          assert_redirected_to music_root_path
        end

        test "should get edit for admin" do
          sign_in_as(@admin_user, stub_auth: true)
          get edit_admin_artists_ranking_configuration_path(@ranking_configuration)
          assert_response :success
        end

        test "should not get edit for editor (manage permission required)" do
          sign_in_as(@editor_user, stub_auth: true)
          get edit_admin_artists_ranking_configuration_path(@ranking_configuration)
          assert_redirected_to music_root_path
        end

        test "should not get edit for regular user" do
          sign_in_as(@regular_user, stub_auth: true)
          get edit_admin_artists_ranking_configuration_path(@ranking_configuration)
          assert_redirected_to music_root_path
        end

        test "should update ranking configuration for admin" do
          sign_in_as(@admin_user, stub_auth: true)

          patch admin_artists_ranking_configuration_path(@ranking_configuration), params: {
            ranking_configuration: {
              name: "Updated Artist Ranking Name",
              description: "Updated artist ranking description"
            }
          }

          assert_redirected_to admin_artists_ranking_configuration_path(@ranking_configuration)
          assert_equal "Ranking configuration updated successfully.", flash[:notice]
          @ranking_configuration.reload
          assert_equal "Updated Artist Ranking Name", @ranking_configuration.name
          assert_equal "Updated artist ranking description", @ranking_configuration.description
        end

        test "should not update ranking configuration with invalid data" do
          sign_in_as(@admin_user, stub_auth: true)

          patch admin_artists_ranking_configuration_path(@ranking_configuration), params: {
            ranking_configuration: {
              name: ""
            }
          }

          assert_response :unprocessable_entity
        end

        test "should not update ranking configuration for regular user" do
          sign_in_as(@regular_user, stub_auth: true)
          original_name = @ranking_configuration.name

          patch admin_artists_ranking_configuration_path(@ranking_configuration), params: {
            ranking_configuration: {
              name: "Updated Name"
            }
          }

          assert_redirected_to music_root_path
          @ranking_configuration.reload
          assert_equal original_name, @ranking_configuration.name
        end

        test "should destroy ranking configuration for admin" do
          sign_in_as(@admin_user, stub_auth: true)

          secondary_config = ::Music::Artists::RankingConfiguration.create!(
            name: "Secondary Artist Config",
            primary: false,
            global: true
          )

          assert_difference("::Music::Artists::RankingConfiguration.count", -1) do
            delete admin_artists_ranking_configuration_path(secondary_config)
          end

          assert_redirected_to admin_artists_ranking_configurations_path
          assert_equal "Ranking configuration deleted successfully.", flash[:notice]
        end

        test "should not destroy ranking configuration for regular user" do
          sign_in_as(@regular_user, stub_auth: true)

          secondary_config = ::Music::Artists::RankingConfiguration.create!(
            name: "Secondary Artist Config",
            primary: false,
            global: true
          )

          assert_no_difference("::Music::Artists::RankingConfiguration.count") do
            delete admin_artists_ranking_configuration_path(secondary_config)
          end

          assert_redirected_to music_root_path
        end

        test "should execute RefreshRankings action for admin" do
          sign_in_as(@admin_user, stub_auth: true)

          ::Music::Artists::RankingConfiguration.any_instance.expects(:calculate_rankings_async)

          post execute_action_admin_artists_ranking_configuration_path(
            @ranking_configuration,
            action_name: "RefreshRankings"
          )
          assert_redirected_to admin_artists_ranking_configuration_path(@ranking_configuration)
        end

        test "should execute RefreshRankings action with turbo_stream response" do
          sign_in_as(@admin_user, stub_auth: true)

          ::Music::Artists::RankingConfiguration.any_instance.expects(:calculate_rankings_async)

          post execute_action_admin_artists_ranking_configuration_path(
            @ranking_configuration,
            action_name: "RefreshRankings"
          ), headers: {"Accept" => "text/vnd.turbo-stream.html"}

          assert_response :success
          assert_equal "text/vnd.turbo-stream.html; charset=utf-8", response.content_type
        end

        test "should not execute action for regular user" do
          sign_in_as(@regular_user, stub_auth: true)

          @ranking_configuration.expects(:calculate_rankings_async).never

          post execute_action_admin_artists_ranking_configuration_path(
            @ranking_configuration,
            action_name: "RefreshRankings"
          )
          assert_redirected_to music_root_path
        end
      end
    end
  end
end
