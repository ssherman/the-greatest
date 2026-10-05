# frozen_string_literal: true

require "test_helper"

# config/storage.yml's private_imports service (Goodreads import spec §3,
# "Storage"). has_one_attached builds its service when the model class loads,
# and production eager-loads, so the service must build even before its
# bucket is configured: an unset variable must fail an upload, never a boot.
class PrivateImportsStorageTest < ActiveSupport::TestCase
  VARIABLES = %w[PRIVATE_IMPORTS_STORAGE_BUCKET PRIVATE_IMPORTS_STORAGE_ENDPOINT
    PRIVATE_IMPORTS_STORAGE_ACCESS_KEY_ID PRIVATE_IMPORTS_STORAGE_SECRET_ACCESS_KEY].freeze

  setup { @saved = VARIABLES.to_h { |name| [name, ENV[name]] } }
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
