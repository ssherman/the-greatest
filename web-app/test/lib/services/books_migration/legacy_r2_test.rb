require "test_helper"

module Services
  module BooksMigration
    class LegacyR2Test < ActiveSupport::TestCase
      setup do
        @original = ENV.to_h.slice(
          "LEGACY_R2_ACCOUNT_ID", "LEGACY_R2_ACCESS_KEY", "LEGACY_R2_SECRET_KEY", "LEGACY_R2_BUCKET"
        )
        ENV["LEGACY_R2_ACCOUNT_ID"] = "test-account"
        ENV["LEGACY_R2_ACCESS_KEY"] = "test-access-key"
        ENV["LEGACY_R2_SECRET_KEY"] = "test-secret-key"
        ENV["LEGACY_R2_BUCKET"] = "test-bucket"
      end

      teardown do
        %w[LEGACY_R2_ACCOUNT_ID LEGACY_R2_ACCESS_KEY LEGACY_R2_SECRET_KEY LEGACY_R2_BUCKET].each { |k| ENV.delete(k) }
        @original.each { |k, v| ENV[k] = v }
      end

      test "endpoint is built from the account id" do
        assert_equal "https://test-account.r2.cloudflarestorage.com", LegacyR2.endpoint
      end

      test "bucket returns the LEGACY_R2_BUCKET env var" do
        assert_equal "test-bucket", LegacyR2.bucket
      end

      test "client is an Aws::S3::Client in region auto" do
        client = LegacyR2.client
        assert_instance_of Aws::S3::Client, client
        assert_equal "auto", client.config.region
      end
    end
  end
end
