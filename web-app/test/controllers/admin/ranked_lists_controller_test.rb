require "test_helper"

module Admin
  class RankedListsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @admin_user = users(:admin_user)
      @regular_user = users(:regular_user)
      @album_config = ranking_configurations(:music_albums_global)
      @song_config = ranking_configurations(:music_songs_global)
      @album_list = lists(:music_albums_list)
      @song_list = lists(:music_songs_list)

      @album_config.ranked_lists.destroy_all
      @song_config.ranked_lists.destroy_all

      host! Rails.application.config.domains[:music]
      sign_in_as(@admin_user, stub_auth: true)
    end

    test "should get index with ranked lists" do
      RankedList.create!(ranking_configuration: @album_config, list: @album_list, weight: 78.5)

      get admin_ranking_configuration_ranked_lists_path(@album_config)
      assert_response :success
      assert_match @album_list.name, response.body
    end

    test "should get index without ranked lists" do
      get admin_ranking_configuration_ranked_lists_path(@album_config)
      assert_response :success
      assert_match "No lists included", response.body
    end

    test "should create ranked_list successfully" do
      assert_difference "RankedList.count", 1 do
        post admin_ranking_configuration_ranked_lists_path(@album_config),
          params: {ranked_list: {list_id: @album_list.id}},
          as: :turbo_stream
      end

      assert_response :success
      assert_match "List added successfully", response.body
    end

    test "should create ranked_list and return turbo stream with 3 replacements" do
      post admin_ranking_configuration_ranked_lists_path(@album_config),
        params: {ranked_list: {list_id: @album_list.id}},
        as: :turbo_stream

      assert_response :success
      assert_turbo_stream action: :replace, target: "flash"
      assert_turbo_stream action: :replace, target: "ranked_lists_list"
      assert_turbo_stream action: :replace, target: "add_list_to_configuration_modal"
    end

    test "should prevent duplicate list addition" do
      RankedList.create!(ranking_configuration: @album_config, list: @album_list)

      assert_no_difference "RankedList.count" do
        post admin_ranking_configuration_ranked_lists_path(@album_config),
          params: {ranked_list: {list_id: @album_list.id}},
          as: :turbo_stream
      end

      assert_response :unprocessable_entity
      assert_match "only be added once", response.body
    end

    test "should get show with calculated_weight_details" do
      ranked_list = RankedList.create!(
        ranking_configuration: @album_config,
        list: @album_list,
        weight: 78.5,
        calculated_weight_details: {
          "timestamp" => "2025-01-15T12:00:00Z",
          "base_values" => {"base_weight" => 100, "minimum_weight" => 10},
          "penalties" => [{"penalty_name" => "Test Penalty", "value" => 15.0}]
        }
      )

      get admin_ranked_list_path(ranked_list)
      assert_response :success
      assert_match "Test Penalty", response.body
    end

    test "should get show handles NULL calculated_weight_details" do
      ranked_list = RankedList.create!(
        ranking_configuration: @album_config,
        list: @album_list,
        weight: nil,
        calculated_weight_details: nil
      )

      get admin_ranked_list_path(ranked_list)
      assert_response :success
      assert_match "Weight has not been calculated yet", response.body
    end

    test "should destroy ranked_list successfully" do
      ranked_list = RankedList.create!(ranking_configuration: @album_config, list: @album_list)

      assert_difference "RankedList.count", -1 do
        delete admin_ranked_list_path(ranked_list), as: :turbo_stream
      end

      assert_response :success
      assert_match "List removed successfully", response.body
    end

    test "should destroy ranked_list and return turbo stream with 3 replacements" do
      ranked_list = RankedList.create!(ranking_configuration: @album_config, list: @album_list)

      delete admin_ranked_list_path(ranked_list), as: :turbo_stream

      assert_response :success
      assert_turbo_stream action: :replace, target: "flash"
      assert_turbo_stream action: :replace, target: "ranked_lists_list"
      assert_turbo_stream action: :replace, target: "add_list_to_configuration_modal"
    end

    test "should enforce admin authorization on create" do
      sign_in_as(@regular_user, stub_auth: true)

      assert_no_difference "RankedList.count" do
        post admin_ranking_configuration_ranked_lists_path(@album_config),
          params: {ranked_list: {list_id: @album_list.id}},
          as: :turbo_stream
      end

      assert_redirected_to music_root_path
    end

    test "should enforce admin authorization on destroy" do
      ranked_list = RankedList.create!(ranking_configuration: @album_config, list: @album_list)
      sign_in_as(@regular_user, stub_auth: true)

      assert_no_difference "RankedList.count" do
        delete admin_ranked_list_path(ranked_list), as: :turbo_stream
      end

      assert_redirected_to music_root_path
    end

    test "should validate media type compatibility - matching type works" do
      assert_difference "RankedList.count", 1 do
        post admin_ranking_configuration_ranked_lists_path(@album_config),
          params: {ranked_list: {list_id: @album_list.id}},
          as: :turbo_stream
      end

      assert_response :success
    end

    test "should validate media type compatibility - mismatched type fails" do
      assert_no_difference "RankedList.count" do
        post admin_ranking_configuration_ranked_lists_path(@album_config),
          params: {ranked_list: {list_id: @song_list.id}},
          as: :turbo_stream
      end

      assert_response :unprocessable_entity
      assert_match "must be a Music::Albums::List", response.body
    end

    test "should work for album ranking configurations" do
      post admin_ranking_configuration_ranked_lists_path(@album_config),
        params: {ranked_list: {list_id: @album_list.id}},
        as: :turbo_stream

      assert_response :success
      assert_equal @album_list, RankedList.last.list
    end

    test "should work for song ranking configurations" do
      post admin_ranking_configuration_ranked_lists_path(@song_config),
        params: {ranked_list: {list_id: @song_list.id}},
        as: :turbo_stream

      assert_response :success
      assert_equal @song_list, RankedList.last.list
    end
  end
end
