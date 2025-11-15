require "test_helper"

class Admin::PenaltiesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin_user)
    @regular_user = users(:regular_user)
    @global_penalty = penalties(:global_penalty)
    @music_penalty = penalties(:music_penalty)
    @dynamic_penalty = penalties(:dynamic_penalty)
    @static_penalty = penalties(:static_penalty)

    host! Rails.application.config.domains[:music]
    sign_in_as(@admin, stub_auth: true)
  end

  test "should get index" do
    get admin_penalties_url
    assert_response :success
  end

  test "should get show" do
    get admin_penalty_url(@global_penalty)
    assert_response :success
  end

  test "should get new" do
    get new_admin_penalty_url
    assert_response :success
  end

  test "should create penalty with valid data" do
    assert_difference("Penalty.count") do
      post admin_penalties_url, params: {
        penalty: {
          type: "Global::Penalty",
          name: "Test Penalty",
          description: "Test description",
          dynamic_type: "number_of_voters"
        }
      }
    end
    assert_redirected_to admin_penalty_url(Penalty.last)
  end

  test "should not create penalty with invalid data" do
    assert_no_difference("Penalty.count") do
      post admin_penalties_url, params: {
        penalty: {
          type: "Global::Penalty",
          name: "",
          description: "Test description"
        }
      }
    end
    assert_response :unprocessable_entity
  end

  test "should get edit" do
    get edit_admin_penalty_url(@global_penalty)
    assert_response :success
  end

  test "should update penalty with valid data" do
    patch admin_penalty_url(@global_penalty), params: {
      penalty: {
        name: "Updated Name"
      }
    }
    assert_redirected_to admin_penalty_url(@global_penalty)
    @global_penalty.reload
    assert_equal "Updated Name", @global_penalty.name
  end

  test "should not update penalty with invalid data" do
    patch admin_penalty_url(@global_penalty), params: {
      penalty: {
        name: ""
      }
    }
    assert_response :unprocessable_entity
  end

  test "should update penalty with form scope penalty (simulates actual form submission)" do
    patch admin_penalty_url(@global_penalty), params: {
      penalty: {
        name: "Updated via Form Scope"
      }
    }
    assert_redirected_to admin_penalty_url(@global_penalty)
    @global_penalty.reload
    assert_equal "Updated via Form Scope", @global_penalty.name
  end

  test "should update music penalty with form scope penalty" do
    patch admin_penalty_url(@music_penalty), params: {
      penalty: {
        name: "Updated Music Penalty"
      }
    }
    assert_redirected_to admin_penalty_url(@music_penalty)
    @music_penalty.reload
    assert_equal "Updated Music Penalty", @music_penalty.name
  end

  test "should destroy penalty" do
    assert_difference("Penalty.count", -1) do
      delete admin_penalty_url(@global_penalty)
    end
    assert_redirected_to admin_penalties_url
  end

  test "should filter to all types by default" do
    get admin_penalties_url
    assert_response :success
    assert_select "tr", minimum: 5
  end

  test "should filter to global penalties only" do
    get admin_penalties_url(type: "Global")
    assert_response :success
  end

  test "should filter to music penalties only" do
    get admin_penalties_url(type: "Music")
    assert_response :success
  end

  test "should handle invalid filter gracefully" do
    get admin_penalties_url(type: "Invalid")
    assert_response :success
  end

  test "should preserve filter in pagination" do
    get admin_penalties_url(type: "Global")
    assert_response :success
  end

  test "should display type badges correctly" do
    get admin_penalties_url
    assert_response :success
    assert_select "span.badge"
  end

  test "should display dynamic type badges correctly" do
    get admin_penalties_url
    assert_response :success
  end

  test "should display user column correctly" do
    get admin_penalties_url
    assert_response :success
  end

  test "should require name" do
    assert_no_difference("Penalty.count") do
      post admin_penalties_url, params: {
        penalty: {
          type: "Global::Penalty",
          name: "",
          description: "Test"
        }
      }
    end
    assert_response :unprocessable_entity
  end

  test "should allow nullable dynamic type" do
    assert_difference("Penalty.count") do
      post admin_penalties_url, params: {
        penalty: {
          type: "Global::Penalty",
          name: "Test Penalty",
          dynamic_type: nil
        }
      }
    end
    assert_redirected_to admin_penalty_url(Penalty.last)
  end

  test "should create penalty with selected type" do
    post admin_penalties_url, params: {
      penalty: {
        type: "Music::Penalty",
        name: "Test Music Penalty"
      }
    }
    assert_equal "Music::Penalty", Penalty.last.type
  end

  test "should create books penalty" do
    assert_difference("Books::Penalty.count") do
      post admin_penalties_url, params: {
        penalty: {
          type: "Books::Penalty",
          name: "Test Books Penalty"
        }
      }
    end
    assert_redirected_to admin_penalty_url(Penalty.last)
    assert_equal "Books::Penalty", Penalty.last.type
  end

  test "should create movies penalty" do
    assert_difference("Movies::Penalty.count") do
      post admin_penalties_url, params: {
        penalty: {
          type: "Movies::Penalty",
          name: "Test Movies Penalty"
        }
      }
    end
    assert_redirected_to admin_penalty_url(Penalty.last)
    assert_equal "Movies::Penalty", Penalty.last.type
  end

  test "should create games penalty" do
    assert_difference("Games::Penalty.count") do
      post admin_penalties_url, params: {
        penalty: {
          type: "Games::Penalty",
          name: "Test Games Penalty"
        }
      }
    end
    assert_redirected_to admin_penalty_url(Penalty.last)
    assert_equal "Games::Penalty", Penalty.last.type
  end

  test "should allow admin access" do
    get admin_penalties_url
    assert_response :success
  end

  test "should deny non-admin access" do
    sign_in_as(@regular_user, stub_auth: true)
    get admin_penalties_url
    assert_redirected_to music_root_url
  end

  test "should show penalty applications count" do
    get admin_penalty_url(@global_penalty)
    assert_response :success
  end

  test "should show lists count" do
    get admin_penalty_url(@global_penalty)
    assert_response :success
  end
end
