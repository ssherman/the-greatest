require "test_helper"

module Admin
  class ListPenaltiesControllerTest < ActionDispatch::IntegrationTest
    setup do
      @admin_user = users(:admin_user)
      @regular_user = users(:regular_user)
      @album_list = lists(:rolling_stone_albums)
      @song_list = lists(:music_songs_list_for_import)
      @global_penalty = penalties(:global_penalty)
      @music_penalty_static = ::Music::Penalty.create!(name: "Static Music Penalty", description: "A static music penalty for testing")
      @music_penalty_dynamic = penalties(:music_penalty)
      @books_penalty = penalties(:books_penalty)
      @dynamic_penalty = penalties(:dynamic_penalty)

      @album_list.list_penalties.destroy_all
      @song_list.list_penalties.destroy_all

      host! Rails.application.config.domains[:music]
      sign_in_as(@admin_user, stub_auth: true)
    end

    test "should get index with penalties" do
      ListPenalty.create!(list: @album_list, penalty: @global_penalty)

      get admin_list_list_penalties_path(@album_list)
      assert_response :success
      assert_match @global_penalty.name, response.body
    end

    test "should get index without penalties" do
      get admin_list_list_penalties_path(@album_list)
      assert_response :success
      assert_match "No penalties attached", response.body
    end

    test "should create list_penalty successfully" do
      assert_difference "ListPenalty.count", 1 do
        post admin_list_list_penalties_path(@album_list),
          params: {list_penalty: {penalty_id: @global_penalty.id}},
          as: :turbo_stream
      end

      assert_response :success
      assert_match "Penalty attached successfully", response.body
    end

    test "should create list_penalty and return turbo stream" do
      post admin_list_list_penalties_path(@album_list),
        params: {list_penalty: {penalty_id: @global_penalty.id}},
        as: :turbo_stream

      assert_response :success
      assert_turbo_stream action: :replace, target: "flash"
      assert_turbo_stream action: :replace, target: "list_penalties_list"
    end

    test "should prevent duplicate penalty attachment" do
      ListPenalty.create!(list: @album_list, penalty: @global_penalty)

      assert_no_difference "ListPenalty.count" do
        post admin_list_list_penalties_path(@album_list),
          params: {list_penalty: {penalty_id: @global_penalty.id}},
          as: :turbo_stream
      end

      assert_response :unprocessable_entity
      assert_match "already been taken", response.body
    end

    test "should destroy list_penalty successfully" do
      list_penalty = ListPenalty.create!(list: @album_list, penalty: @global_penalty)

      assert_difference "ListPenalty.count", -1 do
        delete admin_list_penalty_path(list_penalty), as: :turbo_stream
      end

      assert_response :success
      assert_match "Penalty detached successfully", response.body
    end

    test "should destroy list_penalty and return turbo stream" do
      list_penalty = ListPenalty.create!(list: @album_list, penalty: @global_penalty)

      delete admin_list_penalty_path(list_penalty), as: :turbo_stream

      assert_response :success
      assert_turbo_stream action: :replace, target: "flash"
      assert_turbo_stream action: :replace, target: "list_penalties_list"
    end

    test "should allow Global penalty on Music list" do
      assert_difference "ListPenalty.count", 1 do
        post admin_list_list_penalties_path(@album_list),
          params: {list_penalty: {penalty_id: @global_penalty.id}},
          as: :turbo_stream
      end

      assert_response :success
    end

    test "should allow Music penalty on Music list" do
      assert_difference "ListPenalty.count", 1 do
        post admin_list_list_penalties_path(@album_list),
          params: {list_penalty: {penalty_id: @music_penalty_static.id}},
          as: :turbo_stream
      end

      assert_response :success
    end

    test "should prevent Books penalty on Music list" do
      assert_no_difference "ListPenalty.count" do
        post admin_list_list_penalties_path(@album_list),
          params: {list_penalty: {penalty_id: @books_penalty.id}},
          as: :turbo_stream
      end

      assert_response :unprocessable_entity
      assert_match "cannot be applied to", response.body
    end

    test "should work for song lists" do
      post admin_list_list_penalties_path(@song_list),
        params: {list_penalty: {penalty_id: @global_penalty.id}},
        as: :turbo_stream

      assert_response :success
      assert_equal @song_list, ListPenalty.last.list
    end

    test "should prevent attaching dynamic penalties" do
      assert_no_difference "ListPenalty.count" do
        post admin_list_list_penalties_path(@album_list),
          params: {list_penalty: {penalty_id: @dynamic_penalty.id}},
          as: :turbo_stream
      end

      assert_response :unprocessable_entity
      assert_match "cannot be manually attached", response.body
    end
  end
end
