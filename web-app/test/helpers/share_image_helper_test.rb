require "test_helper"

class ShareImageHelperTest < ActionView::TestCase
  include ShareImageHelper

  setup do
    @book = books_books(:war_and_peace)
  end

  def image_with(metadata)
    image = Image.new(parent: @book, primary: false)
    image.file.attach(ActiveStorage::Blob.create_and_upload!(
      io: File.open(file_fixture("test_image.png")), filename: "c.png",
      content_type: "image/png", metadata: metadata
    ))
    image.save!
    image
  end

  test "returns the public blob url when both dimensions qualify" do
    image = image_with({width: 300, height: 450, analyzed: true})
    assert_equal rails_public_blob_url(image.file), share_image_url(image)
  end

  test "the minimum is inclusive" do
    image = image_with({width: 200, height: 200})
    assert_equal rails_public_blob_url(image.file), share_image_url(image)
  end

  test "nil when too narrow" do
    assert_nil share_image_url(image_with({width: 199, height: 450}))
  end

  test "nil when too short" do
    assert_nil share_image_url(image_with({width: 300, height: 199}))
  end

  test "nil when dimensions are missing" do
    assert_nil share_image_url(image_with({identified: true}))
  end

  test "nil for a nil image" do
    assert_nil share_image_url(nil)
  end

  test "nil when no file is attached" do
    assert_nil share_image_url(Image.new(parent: @book))
  end
end
