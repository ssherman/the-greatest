require "test_helper"

class Admin::ImagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @artist = music_artists(:david_bowie)
    @album = music_albums(:dark_side_of_the_moon)
    @image = images(:david_bowie_photo)
    @image_alt = images(:david_bowie_photo_alt)
    @admin_user = users(:admin_user)
    @editor_user = users(:editor_user)
    @regular_user = users(:regular_user)

    # Attach files to fixture images for validation to pass
    test_image_path = Rails.root.join("test/fixtures/files/test_image.png")
    @image.file.attach(io: File.open(test_image_path), filename: "test.png", content_type: "image/png")
    @image_alt.file.attach(io: File.open(test_image_path), filename: "test_alt.png", content_type: "image/png")

    # Set the host to match the music domain constraint
    host! Rails.application.config.domains[:music]
  end

  # Authentication/Authorization Tests

  test "should redirect to root for unauthenticated users on index" do
    get admin_artist_images_path(@artist)
    assert_redirected_to music_root_path
  end

  test "should redirect to root for regular users on index" do
    sign_in_as(@regular_user, stub_auth: true)
    get admin_artist_images_path(@artist)
    assert_redirected_to music_root_path
  end

  test "should allow admin users to access index" do
    sign_in_as(@admin_user, stub_auth: true)
    get admin_artist_images_path(@artist)
    assert_response :success
  end

  test "should allow editor users to access index" do
    sign_in_as(@editor_user, stub_auth: true)
    get admin_artist_images_path(@artist)
    assert_response :success
  end

  # Index Tests

  test "should get index for artist" do
    sign_in_as(@admin_user, stub_auth: true)
    get admin_artist_images_path(@artist)
    assert_response :success
  end

  test "should get index for album" do
    sign_in_as(@admin_user, stub_auth: true)
    get admin_album_images_path(@album)
    assert_response :success
  end

  # Create Tests

  test "should create image for artist" do
    sign_in_as(@admin_user, stub_auth: true)

    assert_difference("Image.count", 1) do
      post admin_artist_images_path(@artist), params: {
        image: {
          file: fixture_file_upload("test_image.png", "image/png"),
          notes: "New test image",
          primary: false
        }
      }
    end
  end

  test "should create image for album" do
    sign_in_as(@admin_user, stub_auth: true)

    assert_difference("Image.count", 1) do
      post admin_album_images_path(@album), params: {
        image: {
          file: fixture_file_upload("test_image.png", "image/png"),
          notes: "New album cover",
          primary: false
        }
      }
    end
  end

  test "should not create image without file" do
    sign_in_as(@admin_user, stub_auth: true)

    assert_no_difference("Image.count") do
      post admin_artist_images_path(@artist), params: {
        image: {
          notes: "Missing file"
        }
      }
    end
  end

  test "should not create image for regular user" do
    sign_in_as(@regular_user, stub_auth: true)

    assert_no_difference("Image.count") do
      post admin_artist_images_path(@artist), params: {
        image: {
          file: fixture_file_upload("test_image.png", "image/png"),
          notes: "Test"
        }
      }
    end

    assert_redirected_to music_root_path
  end

  # Update Tests

  test "should update image notes for admin" do
    sign_in_as(@admin_user, stub_auth: true)

    patch admin_image_path(@image_alt), params: {
      image: {
        notes: "Updated notes"
      }
    }

    @image_alt.reload
    assert_equal "Updated notes", @image_alt.notes
  end

  test "should update image primary status for admin" do
    sign_in_as(@admin_user, stub_auth: true)

    # image_alt is not primary, set it to primary
    patch admin_image_path(@image_alt), params: {
      image: {
        primary: true
      }
    }

    @image_alt.reload
    assert @image_alt.primary?
  end

  test "should not update image for regular user" do
    sign_in_as(@regular_user, stub_auth: true)

    patch admin_image_path(@image_alt), params: {
      image: {
        notes: "Hacked notes"
      }
    }

    assert_redirected_to music_root_path
    @image_alt.reload
    assert_not_equal "Hacked notes", @image_alt.notes
  end

  # Destroy Tests

  test "should destroy image for admin" do
    sign_in_as(@admin_user, stub_auth: true)

    assert_difference("Image.count", -1) do
      delete admin_image_path(@image_alt)
    end
  end

  test "should not destroy image for regular user" do
    sign_in_as(@regular_user, stub_auth: true)

    assert_no_difference("Image.count") do
      delete admin_image_path(@image_alt)
    end

    assert_redirected_to music_root_path
  end

  # Set Primary Tests

  test "should set image as primary for admin" do
    sign_in_as(@admin_user, stub_auth: true)

    # image_alt is not primary
    assert_not @image_alt.primary?
    # image is primary
    assert @image.primary?

    post set_primary_admin_image_path(@image_alt)

    @image_alt.reload
    @image.reload

    assert @image_alt.primary?
    assert_not @image.primary?
  end

  test "should not set primary for regular user" do
    sign_in_as(@regular_user, stub_auth: true)

    post set_primary_admin_image_path(@image_alt)

    assert_redirected_to music_root_path
    @image_alt.reload
    assert_not @image_alt.primary?
  end

  # Turbo Stream Response Tests

  test "should return turbo stream on successful create" do
    sign_in_as(@admin_user, stub_auth: true)

    post admin_artist_images_path(@artist), params: {
      image: {
        file: fixture_file_upload("test_image.png", "image/png"),
        notes: "Test"
      }
    }, as: :turbo_stream

    assert_response :success
    assert_match(/turbo-stream/, response.content_type)
  end

  test "should return turbo stream on successful update" do
    sign_in_as(@admin_user, stub_auth: true)

    patch admin_image_path(@image_alt), params: {
      image: {notes: "Updated"}
    }, as: :turbo_stream

    assert_response :success
    assert_match(/turbo-stream/, response.content_type)
  end

  test "should return turbo stream on successful destroy" do
    sign_in_as(@admin_user, stub_auth: true)

    delete admin_image_path(@image_alt), as: :turbo_stream

    assert_response :success
    assert_match(/turbo-stream/, response.content_type)
  end

  test "should return turbo stream on set_primary" do
    sign_in_as(@admin_user, stub_auth: true)

    post set_primary_admin_image_path(@image_alt), as: :turbo_stream

    assert_response :success
    assert_match(/turbo-stream/, response.content_type)
  end
end

class Admin::GamesImagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @game = games_games(:breath_of_the_wild)
    @company = games_companies(:nintendo)
    @admin_user = users(:admin_user)

    host! Rails.application.config.domains[:games]
    sign_in_as(@admin_user, stub_auth: true)
  end

  test "should get index for game" do
    get admin_games_game_images_path(@game)
    assert_response :success
  end

  test "should get index for company" do
    get admin_games_company_images_path(@company)
    assert_response :success
  end

  test "should create image for game" do
    assert_difference("Image.count", 1) do
      post admin_games_game_images_path(@game), params: {
        image: {
          file: fixture_file_upload("test_image.png", "image/png"),
          notes: "Game cover art",
          primary: false
        }
      }
    end
  end

  test "should create image for company" do
    assert_difference("Image.count", 1) do
      post admin_games_company_images_path(@company), params: {
        image: {
          file: fixture_file_upload("test_image.png", "image/png"),
          notes: "Company logo",
          primary: false
        }
      }
    end
  end
end
