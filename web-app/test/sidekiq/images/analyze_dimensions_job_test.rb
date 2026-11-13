require "test_helper"

module Images
  class AnalyzeDimensionsJobTest < ActiveSupport::TestCase
    def unmeasured_blob
      ActiveStorage::Blob.create_and_upload!(
        io: file_fixture("test_image.png").open,
        filename: "test_image.png",
        content_type: "image/png",
        metadata: {identified: true}
      )
    end

    test "measures a blob that was identified but never analyzed" do
      blob = unmeasured_blob
      assert_nil blob.metadata["width"]

      AnalyzeDimensionsJob.new.perform([blob.id])

      blob.reload
      assert_kind_of Integer, blob.metadata["width"]
      assert_kind_of Integer, blob.metadata["height"]
    end

    test "does not re-analyze a blob that already has a width" do
      blob = unmeasured_blob
      blob.update!(metadata: blob.metadata.merge("width" => 10, "height" => 10))

      ActiveStorage::Blob.any_instance.expects(:analyze).never

      AnalyzeDimensionsJob.new.perform([blob.id])
    end

    test "a failing blob is logged and the rest of the batch still runs" do
      bad = unmeasured_blob
      good = unmeasured_blob
      bad.stubs(:analyze).raises(StandardError, "boom")
      ActiveStorage::Blob.stubs(:where).with(id: [bad.id, good.id]).returns([bad, good])
      Rails.logger.expects(:error).with { |message| message.include?("blob #{bad.id}") }

      assert_nothing_raised { AnalyzeDimensionsJob.new.perform([bad.id, good.id]) }

      assert_nil bad.reload.metadata["width"]
      assert_kind_of Integer, good.reload.metadata["width"]
    end

    test "skips an unknown id without error" do
      assert_nothing_raised { AnalyzeDimensionsJob.new.perform([0]) }
    end
  end
end
