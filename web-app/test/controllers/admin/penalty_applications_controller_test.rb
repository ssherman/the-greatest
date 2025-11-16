require "test_helper"

module Admin
  class PenaltyApplicationsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @admin_user = users(:admin_user)
      @regular_user = users(:regular_user)
      @album_config = ranking_configurations(:music_albums_global)
      @song_config = ranking_configurations(:music_songs_global)
      @global_penalty = penalties(:global_penalty)
      @music_penalty = penalties(:music_penalty)
      @books_penalty = penalties(:books_penalty)

      @album_config.penalty_applications.destroy_all
      @song_config.penalty_applications.destroy_all

      host! Rails.application.config.domains[:music]
      sign_in_as(@admin_user, stub_auth: true)
    end

    test "should get index with penalty applications" do
      PenaltyApplication.create!(ranking_configuration: @album_config, penalty: @global_penalty, value: 75)

      get admin_ranking_configuration_penalty_applications_path(@album_config)
      assert_response :success
      assert_match @global_penalty.name, response.body
    end

    test "should get index without penalty applications" do
      get admin_ranking_configuration_penalty_applications_path(@album_config)
      assert_response :success
      assert_match "No penalties attached", response.body
    end

    test "should create penalty_application successfully" do
      assert_difference "PenaltyApplication.count", 1 do
        post admin_ranking_configuration_penalty_applications_path(@album_config),
          params: {penalty_application: {penalty_id: @global_penalty.id, value: 75}},
          as: :turbo_stream
      end

      assert_response :success
      assert_match "Penalty attached successfully", response.body
      assert_equal 75, PenaltyApplication.last.value
    end

    test "should create penalty_application and return turbo stream with 3 replacements" do
      post admin_ranking_configuration_penalty_applications_path(@album_config),
        params: {penalty_application: {penalty_id: @global_penalty.id, value: 75}},
        as: :turbo_stream

      assert_response :success
      assert_turbo_stream action: :replace, target: "flash"
      assert_turbo_stream action: :replace, target: "penalty_applications_list"
      assert_turbo_stream action: :replace, target: "add_penalty_to_configuration_modal"
    end

    test "should validate value too low on create" do
      assert_no_difference "PenaltyApplication.count" do
        post admin_ranking_configuration_penalty_applications_path(@album_config),
          params: {penalty_application: {penalty_id: @global_penalty.id, value: -1}},
          as: :turbo_stream
      end

      assert_response :unprocessable_entity
      assert_match "greater than or equal to", response.body
    end

    test "should validate value too high on create" do
      assert_no_difference "PenaltyApplication.count" do
        post admin_ranking_configuration_penalty_applications_path(@album_config),
          params: {penalty_application: {penalty_id: @global_penalty.id, value: 101}},
          as: :turbo_stream
      end

      assert_response :unprocessable_entity
      assert_match "less than or equal to", response.body
    end

    test "should prevent duplicate penalty application" do
      PenaltyApplication.create!(ranking_configuration: @album_config, penalty: @global_penalty, value: 50)

      assert_no_difference "PenaltyApplication.count" do
        post admin_ranking_configuration_penalty_applications_path(@album_config),
          params: {penalty_application: {penalty_id: @global_penalty.id, value: 75}},
          as: :turbo_stream
      end

      assert_response :unprocessable_entity
      assert_match "already been taken", response.body
    end

    test "should update penalty_application value successfully" do
      penalty_application = PenaltyApplication.create!(ranking_configuration: @album_config, penalty: @global_penalty, value: 75)

      patch admin_penalty_application_path(penalty_application),
        params: {penalty_application: {value: 50}},
        as: :turbo_stream

      assert_response :success
      assert_match "Penalty application updated successfully", response.body
      assert_equal 50, penalty_application.reload.value
    end

    test "should update penalty_application and return turbo stream with 2 replacements" do
      penalty_application = PenaltyApplication.create!(ranking_configuration: @album_config, penalty: @global_penalty, value: 75)

      patch admin_penalty_application_path(penalty_application),
        params: {penalty_application: {value: 50}},
        as: :turbo_stream

      assert_response :success
      assert_turbo_stream action: :replace, target: "flash"
      assert_turbo_stream action: :replace, target: "penalty_applications_list"
    end

    test "should validate value too low on update" do
      penalty_application = PenaltyApplication.create!(ranking_configuration: @album_config, penalty: @global_penalty, value: 75)

      patch admin_penalty_application_path(penalty_application),
        params: {penalty_application: {value: -1}},
        as: :turbo_stream

      assert_response :unprocessable_entity
      assert_match "greater than or equal to", response.body
    end

    test "should validate value too high on update" do
      penalty_application = PenaltyApplication.create!(ranking_configuration: @album_config, penalty: @global_penalty, value: 75)

      patch admin_penalty_application_path(penalty_application),
        params: {penalty_application: {value: 101}},
        as: :turbo_stream

      assert_response :unprocessable_entity
      assert_match "less than or equal to", response.body
    end

    test "should destroy penalty_application successfully" do
      penalty_application = PenaltyApplication.create!(ranking_configuration: @album_config, penalty: @global_penalty, value: 75)

      assert_difference "PenaltyApplication.count", -1 do
        delete admin_penalty_application_path(penalty_application), as: :turbo_stream
      end

      assert_response :success
      assert_match "Penalty detached successfully", response.body
    end

    test "should destroy penalty_application and return turbo stream with 3 replacements" do
      penalty_application = PenaltyApplication.create!(ranking_configuration: @album_config, penalty: @global_penalty, value: 75)

      delete admin_penalty_application_path(penalty_application), as: :turbo_stream

      assert_response :success
      assert_turbo_stream action: :replace, target: "flash"
      assert_turbo_stream action: :replace, target: "penalty_applications_list"
      assert_turbo_stream action: :replace, target: "add_penalty_to_configuration_modal"
    end

    test "should allow Global penalty on Music configuration" do
      assert_difference "PenaltyApplication.count", 1 do
        post admin_ranking_configuration_penalty_applications_path(@album_config),
          params: {penalty_application: {penalty_id: @global_penalty.id, value: 75}},
          as: :turbo_stream
      end

      assert_response :success
    end

    test "should allow Music penalty on Music configuration" do
      assert_difference "PenaltyApplication.count", 1 do
        post admin_ranking_configuration_penalty_applications_path(@album_config),
          params: {penalty_application: {penalty_id: @music_penalty.id, value: 75}},
          as: :turbo_stream
      end

      assert_response :success
    end

    test "should prevent Books penalty on Music configuration" do
      assert_no_difference "PenaltyApplication.count" do
        post admin_ranking_configuration_penalty_applications_path(@album_config),
          params: {penalty_application: {penalty_id: @books_penalty.id, value: 75}},
          as: :turbo_stream
      end

      assert_response :unprocessable_entity
      assert_match "cannot be applied to", response.body
    end

    test "should work for album configurations" do
      post admin_ranking_configuration_penalty_applications_path(@album_config),
        params: {penalty_application: {penalty_id: @global_penalty.id, value: 75}},
        as: :turbo_stream

      assert_response :success
      assert_equal @album_config, PenaltyApplication.last.ranking_configuration
    end

    test "should work for song configurations" do
      post admin_ranking_configuration_penalty_applications_path(@song_config),
        params: {penalty_application: {penalty_id: @global_penalty.id, value: 75}},
        as: :turbo_stream

      assert_response :success
      assert_equal @song_config, PenaltyApplication.last.ranking_configuration
    end
  end
end
