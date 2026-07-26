require "test_helper"

module Books
  class MigrateCoverImageJobTest < ActiveSupport::TestCase
    setup do
      @book = Books::Book.create!(title: "Cover Migration Book")
    end

    def s3_response(bytes)
      Struct.new(:body).new(StringIO.new(bytes))
    end

    def stub_legacy_r2
      client = mock
      Services::BooksMigration::LegacyR2.stubs(:client).returns(client)
      Services::BooksMigration::LegacyR2.stubs(:bucket).returns("legacy-bucket")
      client
    end

    test "fetches the original from legacy R2 and creates a primary Image with provenance" do
      client = stub_legacy_r2
      client.expects(:get_object)
        .with(bucket: "legacy-bucket", key: "blobkey123")
        .returns(s3_response("fake-jpeg-bytes"))

      Books::MigrateCoverImageJob.new.perform(@book.id, "blobkey123", "cover.jpg", "image/jpeg")

      image = @book.reload.images.where(primary: true).first
      assert_not_nil image
      assert image.file.attached?
      assert_equal "cover.jpg", image.file.filename.to_s
      assert_equal "image/jpeg", image.file.blob.content_type
      assert_equal "legacy_migration", image.metadata["source"]
      assert_equal "blobkey123", image.metadata["legacy_blob_key"]
    end

    test "skips (no R2 fetch) when the book already has a primary image" do
      existing = @book.images.build(primary: true)
      existing.file.attach(io: StringIO.new("existing"), filename: "existing.jpg", content_type: "image/jpeg")
      existing.save!

      Services::BooksMigration::LegacyR2.expects(:client).never

      Books::MigrateCoverImageJob.new.perform(@book.id, "blobkey123", "cover.jpg", "image/jpeg")

      assert_equal 1, @book.reload.images.where(primary: true).count
    end

    test "skips (no R2 fetch, no raise) when the book does not exist" do
      Services::BooksMigration::LegacyR2.expects(:client).never
      missing_id = Books::Book.maximum(:id).to_i + 999_999

      assert_nothing_raised do
        Books::MigrateCoverImageJob.new.perform(missing_id, "blobkey123", "cover.jpg", "image/jpeg")
      end
    end

    test "re-running for the same book creates no duplicate image" do
      client = stub_legacy_r2
      client.stubs(:get_object).returns(s3_response("fake-jpeg-bytes"))

      job = Books::MigrateCoverImageJob.new
      job.perform(@book.id, "blobkey123", "cover.jpg", "image/jpeg")
      job.perform(@book.id, "blobkey123", "cover.jpg", "image/jpeg")

      @book.reload
      assert_equal 1, @book.images.where(primary: true).count
      assert_equal 1, @book.images.count
    end

    test "is configured to retry" do
      assert_equal 5, Books::MigrateCoverImageJob.get_sidekiq_options["retry"]
    end
  end
end
