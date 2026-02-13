require "test_helper"

module Admin
  module Games
    class RankingConfigurationsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @ranking_configuration = ranking_configurations(:games_global)
        @admin_user = users(:admin_user)
        @editor_user = users(:editor_user)
        @regular_user = users(:regular_user)

        # Set the host to match the games domain constraint
        host! Rails.application.config.domains[:games]
      end

      # Authentication/Authorization Tests

      test "should redirect index to root for unauthenticated users" do
        get admin_games_ranking_configurations_path
        assert_redirected_to games_root_path
        assert_equal "Access denied. You need permission for games admin.", flash[:alert]
      end

      test "should redirect to root for regular users" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_games_ranking_configurations_path
        assert_redirected_to games_root_path
        assert_equal "Access denied. You need permission for games admin.", flash[:alert]
      end

      test "should allow admin users to access index" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_ranking_configurations_path
        assert_response :success
      end

      test "should allow editor users to access index" do
        sign_in_as(@editor_user, stub_auth: true)
        get admin_games_ranking_configurations_path
        assert_response :success
      end

      # Index Tests

      test "should get index without search" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_ranking_configurations_path
        assert_response :success
      end

      test "should get index with search query" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_ranking_configurations_path(q: "Global")
        assert_response :success
      end

      test "should handle empty search results without error" do
        sign_in_as(@admin_user, stub_auth: true)

        assert_nothing_raised do
          get admin_games_ranking_configurations_path(q: "nonexistentconfig")
        end

        assert_response :success
      end

      test "should handle sorting by name" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_ranking_configurations_path(sort: "name")
        assert_response :success
      end

      test "should handle sorting by id" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_ranking_configurations_path(sort: "id")
        assert_response :success
      end

      test "should handle sorting by algorithm_version" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_ranking_configurations_path(sort: "algorithm_version")
        assert_response :success
      end

      test "should reject invalid sort parameters and default to name" do
        sign_in_as(@admin_user, stub_auth: true)

        assert_nothing_raised do
          get admin_games_ranking_configurations_path(sort: "'; DROP TABLE ranking_configurations; --")
        end
        assert_response :success

        assert ::Games::RankingConfiguration.count > 0
      end

      test "should only allow whitelisted sort columns" do
        sign_in_as(@admin_user, stub_auth: true)

        # Valid columns should work
        ["id", "name", "algorithm_version", "published_at", "created_at"].each do |column|
          get admin_games_ranking_configurations_path(sort: column)
          assert_response :success
        end

        # Invalid columns should default to name (no error)
        ["description", "invalid", "ranking_configurations.id; --"].each do |column|
          get admin_games_ranking_configurations_path(sort: column)
          assert_response :success
        end
      end

      test "should paginate results" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_ranking_configurations_path
        assert_response :success
      end

      # Show Tests

      test "should get show for admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_ranking_configuration_path(@ranking_configuration)
        assert_response :success
      end

      test "should get show for editor" do
        sign_in_as(@editor_user, stub_auth: true)
        get admin_games_ranking_configuration_path(@ranking_configuration)
        assert_response :success
      end

      test "should not get show for regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_games_ranking_configuration_path(@ranking_configuration)
        assert_redirected_to games_root_path
      end

      test "should load ranking configuration with associations" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_ranking_configuration_path(@ranking_configuration)
        assert_response :success
      end

      # New Tests

      test "should get new for admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get new_admin_games_ranking_configuration_path
        assert_response :success
      end

      test "should not get new for editor (manage permission required)" do
        sign_in_as(@editor_user, stub_auth: true)
        get new_admin_games_ranking_configuration_path
        assert_redirected_to games_root_path
      end

      test "should not get new for regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get new_admin_games_ranking_configuration_path
        assert_redirected_to games_root_path
      end

      # Create Tests

      test "should create ranking configuration for admin with valid params" do
        sign_in_as(@admin_user, stub_auth: true)

        assert_difference("::Games::RankingConfiguration.count", 1) do
          post admin_games_ranking_configurations_path, params: {
            ranking_configuration: {
              name: "New Test Games Configuration",
              description: "Test description",
              global: true,
              primary: false,
              algorithm_version: 1,
              exponent: 3.0,
              bonus_pool_percentage: 3.0,
              min_list_weight: 1
            }
          }
        end

        assert_redirected_to admin_games_ranking_configuration_path(::Games::RankingConfiguration.last)
        assert_equal "Ranking configuration created successfully.", flash[:notice]
      end

      test "should not create ranking configuration with invalid data" do
        sign_in_as(@admin_user, stub_auth: true)

        assert_no_difference("::Games::RankingConfiguration.count") do
          post admin_games_ranking_configurations_path, params: {
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

        assert_no_difference("::Games::RankingConfiguration.count") do
          post admin_games_ranking_configurations_path, params: {
            ranking_configuration: {
              name: "New Test Configuration",
              global: true,
              primary: false
            }
          }
        end

        assert_redirected_to games_root_path
      end

      # Edit Tests

      test "should get edit for admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get edit_admin_games_ranking_configuration_path(@ranking_configuration)
        assert_response :success
      end

      test "should not get edit for editor (manage permission required)" do
        sign_in_as(@editor_user, stub_auth: true)
        get edit_admin_games_ranking_configuration_path(@ranking_configuration)
        assert_redirected_to games_root_path
      end

      test "should not get edit for regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get edit_admin_games_ranking_configuration_path(@ranking_configuration)
        assert_redirected_to games_root_path
      end

      # Update Tests

      test "should update ranking configuration for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        patch admin_games_ranking_configuration_path(@ranking_configuration), params: {
          ranking_configuration: {
            name: "Updated Games Name",
            description: "Updated description"
          }
        }

        assert_redirected_to admin_games_ranking_configuration_path(@ranking_configuration)
        assert_equal "Ranking configuration updated successfully.", flash[:notice]
        @ranking_configuration.reload
        assert_equal "Updated Games Name", @ranking_configuration.name
        assert_equal "Updated description", @ranking_configuration.description
      end

      test "should not update ranking configuration with invalid data" do
        sign_in_as(@admin_user, stub_auth: true)

        patch admin_games_ranking_configuration_path(@ranking_configuration), params: {
          ranking_configuration: {
            name: ""
          }
        }

        assert_response :unprocessable_entity
      end

      test "should not update ranking configuration for regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        original_name = @ranking_configuration.name

        patch admin_games_ranking_configuration_path(@ranking_configuration), params: {
          ranking_configuration: {
            name: "Updated Name"
          }
        }

        assert_redirected_to games_root_path
        @ranking_configuration.reload
        assert_equal original_name, @ranking_configuration.name
      end

      # Destroy Tests

      test "should destroy ranking configuration for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        # Create a non-primary config to delete (the fixture is primary)
        config_to_delete = ::Games::RankingConfiguration.create!(
          name: "Deletable Games Config",
          global: true,
          primary: false
        )

        assert_difference("::Games::RankingConfiguration.count", -1) do
          delete admin_games_ranking_configuration_path(config_to_delete)
        end

        assert_redirected_to admin_games_ranking_configurations_path
        assert_equal "Ranking configuration deleted successfully.", flash[:notice]
      end

      test "should not destroy ranking configuration for regular user" do
        sign_in_as(@regular_user, stub_auth: true)

        assert_no_difference("::Games::RankingConfiguration.count") do
          delete admin_games_ranking_configuration_path(@ranking_configuration)
        end

        assert_redirected_to games_root_path
      end

      # Execute Action Tests

      test "should execute action for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        ::Games::RankingConfiguration.any_instance.expects(:calculate_rankings_async)

        post execute_action_admin_games_ranking_configuration_path(
          @ranking_configuration,
          action_name: "RefreshRankings"
        )
        assert_redirected_to admin_games_ranking_configuration_path(@ranking_configuration)
      end

      test "should execute action with turbo_stream response" do
        sign_in_as(@admin_user, stub_auth: true)

        ::Games::RankingConfiguration.any_instance.expects(:calculate_rankings_async)

        post execute_action_admin_games_ranking_configuration_path(
          @ranking_configuration,
          action_name: "RefreshRankings"
        ), headers: {"Accept" => "text/vnd.turbo-stream.html"}

        assert_response :success
        assert_equal "text/vnd.turbo-stream.html; charset=utf-8", response.content_type
      end

      test "should not execute action for regular user" do
        sign_in_as(@regular_user, stub_auth: true)

        @ranking_configuration.expects(:calculate_rankings_async).never

        post execute_action_admin_games_ranking_configuration_path(
          @ranking_configuration,
          action_name: "RefreshRankings"
        )
        assert_redirected_to games_root_path
      end

      test "should reject non-whitelisted execute action names" do
        sign_in_as(@admin_user, stub_auth: true)

        post execute_action_admin_games_ranking_configuration_path(
          @ranking_configuration,
          action_name: "Music::MergeSong"
        )
        assert_response :bad_request
      end

      test "should reject arbitrary execute action names" do
        sign_in_as(@admin_user, stub_auth: true)

        post execute_action_admin_games_ranking_configuration_path(
          @ranking_configuration,
          action_name: "NonExistentAction"
        )
        assert_response :bad_request
      end

      # Index Action Tests

      test "should execute index action for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        BulkCalculateWeightsJob.expects(:perform_async).with(@ranking_configuration.id)

        post index_action_admin_games_ranking_configurations_path(
          action_name: "BulkCalculateWeights",
          ranking_configuration_ids: [@ranking_configuration.id]
        )

        assert_redirected_to admin_games_ranking_configurations_path
      end

      test "should execute index action with turbo_stream response" do
        sign_in_as(@admin_user, stub_auth: true)

        BulkCalculateWeightsJob.expects(:perform_async).with(@ranking_configuration.id)

        post index_action_admin_games_ranking_configurations_path(
          action_name: "BulkCalculateWeights",
          ranking_configuration_ids: [@ranking_configuration.id]
        ), headers: {"Accept" => "text/vnd.turbo-stream.html"}

        assert_response :success
        assert_equal "text/vnd.turbo-stream.html; charset=utf-8", response.content_type
      end

      test "should execute index action without any IDs and process all configurations" do
        sign_in_as(@admin_user, stub_auth: true)

        # When no IDs provided, should process ALL configurations of this type
        secondary_configuration = ranking_configurations(:games_secondary)
        BulkCalculateWeightsJob.expects(:perform_async).with(@ranking_configuration.id)
        BulkCalculateWeightsJob.expects(:perform_async).with(secondary_configuration.id)

        post index_action_admin_games_ranking_configurations_path(
          action_name: "BulkCalculateWeights"
        )

        assert_redirected_to admin_games_ranking_configurations_path
      end

      test "should not execute index action for regular user" do
        sign_in_as(@regular_user, stub_auth: true)

        BulkCalculateWeightsJob.expects(:perform_async).never

        post index_action_admin_games_ranking_configurations_path(
          action_name: "BulkCalculateWeights",
          ranking_configuration_ids: [@ranking_configuration.id]
        )

        assert_redirected_to games_root_path
      end

      test "should reject non-whitelisted index action names" do
        sign_in_as(@admin_user, stub_auth: true)

        post index_action_admin_games_ranking_configurations_path(
          action_name: "Music::RefreshAllArtistsRankings"
        )
        assert_response :bad_request
      end
    end
  end
end
