require "test_helper"

class ImageTest < ActiveSupport::TestCase
  include ActionDispatch::TestProcess::FixtureFile

  test "image belongs to polymorphic parent" do
    image = images(:david_bowie_photo)
    assert_equal Music::Artist, image.parent.class
    assert_equal "David Bowie", image.parent.name
  end

  test "image belongs to album" do
    image = images(:dark_side_cover)
    assert_equal Music::Album, image.parent.class
    assert_equal "The Dark Side of the Moon", image.parent.title
  end

  test "image stores metadata correctly" do
    image = images(:david_bowie_photo)
    assert_respond_to image, :analyzed
    assert_respond_to image, :identified
  end

  test "primary images work correctly" do
    artist = music_artists(:david_bowie)
    primary_image = images(:david_bowie_photo)

    assert primary_image.primary?
    assert_equal primary_image, artist.primary_image
  end

  test "setting primary automatically unsets others" do
    artist = music_artists(:david_bowie)
    original_primary = images(:david_bowie_photo)
    alt_image = images(:david_bowie_photo_alt)

    assert original_primary.primary?
    assert_not alt_image.primary?

    # Create a new primary image - should automatically unset the other
    new_image = Image.new(
      parent: artist,
      primary: true,
      notes: "Another primary image"
    )

    # Create a fake file attachment
    new_image.file.attach(
      io: StringIO.new("fake image data"),
      filename: "test.jpg",
      content_type: "image/jpeg"
    )

    new_image.save!

    # Check that original primary is now false
    original_primary.reload
    assert_not original_primary.primary?
    assert new_image.primary?
    assert_equal new_image, artist.reload.primary_image
  end

  test "setting new primary unsets others" do
    artist = music_artists(:david_bowie)
    original_primary = images(:david_bowie_photo)
    alt_image = images(:david_bowie_photo_alt)

    assert original_primary.primary?
    assert_not alt_image.primary?

    # Set alt image as primary (bypass file validation for this test)
    alt_image.update_column(:primary, true)
    alt_image.send(:unset_other_primary_images)

    # Reload and check
    original_primary.reload
    alt_image.reload

    assert_not original_primary.primary?
    assert alt_image.primary?
    assert_equal alt_image, artist.reload.primary_image
  end

  test "primary scope works" do
    primary_images = Image.primary
    assert_includes primary_images, images(:david_bowie_photo)
    assert_includes primary_images, images(:dark_side_cover)
    assert_not_includes primary_images, images(:david_bowie_photo_alt)
  end

  test "non_primary scope works" do
    non_primary_images = Image.non_primary
    assert_includes non_primary_images, images(:david_bowie_photo_alt)
    assert_includes non_primary_images, images(:dark_side_alt_cover)
    assert_not_includes non_primary_images, images(:david_bowie_photo)
  end

  test "can have multiple non-primary images" do
    album = music_albums(:dark_side_of_the_moon)
    primary_image = images(:dark_side_cover)
    alt_image = images(:dark_side_alt_cover)

    assert primary_image.primary?
    assert_not alt_image.primary?
    assert_equal 2, album.images.count
    assert_equal 1, album.images.primary.count
    assert_equal 1, album.images.non_primary.count
  end

  test "release images work correctly" do
    release = music_releases(:dark_side_original)
    release_image = images(:dark_side_original_release_cover)

    assert_equal Music::Release, release_image.parent.class
    assert_equal "Original Release", release_image.parent.release_name
    assert release_image.primary?
    assert_equal release_image, release.primary_image
  end

  test "multiple releases can have different primary images" do
    original_release = music_releases(:dark_side_original)
    remaster_release = music_releases(:dark_side_remaster)

    original_image = images(:dark_side_original_release_cover)
    remaster_image = images(:dark_side_remaster_cover)

    assert original_image.primary?
    assert remaster_image.primary?
    assert_equal original_image, original_release.primary_image
    assert_equal remaster_image, remaster_release.primary_image
  end
end
