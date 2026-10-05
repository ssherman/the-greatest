# frozen_string_literal: true

require "test_helper"

# config/storage.yml's private_imports service (Goodreads import spec §3,
# "Storage"). has_one_attached builds its service when the model class loads,
# and production eager-loads, so the service must build even before its
# bucket is configured: an unset variable must fail an upload, never a boot.
class PrivateImportsStorageTest < ActiveSupport::TestCase
  VARIABLES = %w[PRIVATE_IMPORTS_STORAGE_BUCKET PRIVATE_IMPORTS_STORAGE_ENDPOINT
    PRIVATE_IMPORTS_STORAGE_ACCESS_KEY_ID PRIVATE_IMPORTS_STORAGE_SECRET_ACCESS_KEY].freeze
  # With no keys configured the AWS SDK walks its credential chain: AWS_*
  # variables, then ~/.aws files, then the instance metadata endpoint (an
  # HTTP call WebMock refuses on CI). Each test is a host with none of them,
  # so it runs the same on a laptop with ~/.aws as on CI.
  AWS_VARIABLES = %w[AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE
    AWS_SHARED_CREDENTIALS_FILE AWS_CONFIG_FILE AWS_EC2_METADATA_DISABLED].freeze

  setup do
    @saved = (VARIABLES + AWS_VARIABLES).to_h { |name| [name, ENV[name]] }
    AWS_VARIABLES.each { |name| ENV[name] = nil }
    ENV["AWS_SHARED_CREDENTIALS_FILE"] = ENV["AWS_CONFIG_FILE"] = "/nonexistent/aws"
    ENV["AWS_EC2_METADATA_DISABLED"] = "true"
  end

  teardown { @saved.each { |name, value| ENV[name] = value } }

  def service_for(environment, **variables)
    VARIABLES.each { |name| ENV[name] = nil }
    variables.each { |name, value| ENV[name.to_s] = value }
    Rails.stubs(:env).returns(ActiveSupport::EnvironmentInquirer.new(environment))
    configurations = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/storage.yml"))
    ActiveStorage::Service.configure(:private_imports, configurations)
  end

  test "production builds a private S3 service before its bucket is configured" do
    service = service_for("production")

    assert_kind_of ActiveStorage::Service::S3Service, service
    assert_equal ["private-imports-unconfigured", false], [service.bucket.name, service.public?]
  end

  test "production uses the configured bucket, and it is never public" do
    service = service_for("production", PRIVATE_IMPORTS_STORAGE_BUCKET: "tgb-private-imports")

    assert_equal ["tgb-private-imports", false], [service.bucket.name, service.public?]
  end

  test "test, and development without a bucket, keep pages on disk" do
    assert_kind_of ActiveStorage::Service::DiskService, service_for("test")
    assert_kind_of ActiveStorage::Service::DiskService, service_for("development")
  end
end
