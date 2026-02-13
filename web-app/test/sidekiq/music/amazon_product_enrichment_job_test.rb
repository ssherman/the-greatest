# frozen_string_literal: true

require "test_helper"

module Music
  class AmazonProductEnrichmentJobTest < ActiveSupport::TestCase
    def setup
      @album = music_albums(:dark_side_of_the_moon)
      @job = AmazonProductEnrichmentJob.new
    end

    test "perform calls AmazonProductService with album" do
      mock_service_result = {success: true, data: "Amazon enrichment completed"}

      Services::Music::AmazonProductService.expects(:call)
        .with(album: @album)
        .returns(mock_service_result)

      assert_nothing_raised do
        @job.perform(@album.id)
      end
    end

    test "perform logs success when service succeeds" do
      mock_service_result = {success: true, data: "Amazon enrichment completed"}

      Services::Music::AmazonProductService.stubs(:call).returns(mock_service_result)

      Rails.logger.expects(:info).with("Starting Amazon product enrichment for album: #{@album.title}")
      Rails.logger.expects(:info).with("Successfully enriched album #{@album.title} with Amazon data")

      @job.perform(@album.id)
    end

    test "perform logs error and raises when service fails" do
      mock_service_result = {
        success: false,
        error: "API error",
        errors: ["Network timeout", "Invalid response"]
      }

      Services::Music::AmazonProductService.stubs(:call).returns(mock_service_result)

      Rails.logger.expects(:info).with("Starting Amazon product enrichment for album: #{@album.title}")
      Rails.logger.expects(:error).with("Failed to enrich album #{@album.title}: API error")

      error = assert_raises(StandardError) do
        @job.perform(@album.id)
      end

      assert_equal "Amazon enrichment failed: API error", error.message
    end

    test "perform logs error and raises when service returns error without errors array" do
      mock_service_result = {
        success: false,
        error: "API credentials missing"
      }

      Services::Music::AmazonProductService.stubs(:call).returns(mock_service_result)

      Rails.logger.expects(:error).with("Failed to enrich album #{@album.title}: API credentials missing")

      error = assert_raises(StandardError) do
        @job.perform(@album.id)
      end

      assert_equal "Amazon enrichment failed: API credentials missing", error.message
    end

    test "perform handles unknown error gracefully" do
      mock_service_result = {success: false}

      Services::Music::AmazonProductService.stubs(:call).returns(mock_service_result)

      Rails.logger.expects(:error).with("Failed to enrich album #{@album.title}: Unknown error")

      error = assert_raises(StandardError) do
        @job.perform(@album.id)
      end

      assert_equal "Amazon enrichment failed: Unknown error", error.message
    end

    test "perform finds album by id" do
      ::Music::Album.expects(:find).with(@album.id).returns(@album)
      Services::Music::AmazonProductService.stubs(:call).returns({success: true})

      @job.perform(@album.id)
    end

    test "job is configured for serial queue" do
      assert_equal :serial, AmazonProductEnrichmentJob.get_sidekiq_options["queue"]
    end

    test "job includes Sidekiq::Job" do
      assert AmazonProductEnrichmentJob.include?(Sidekiq::Job)
    end
  end
end
