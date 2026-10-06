require "test_helper"

module Services
  module Books
    module GoodreadsImports
      class ValidateUploadTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        setup do
          @user = User.create!(email: "uploader@example.com", role: :user, email_verified: false)
        end

        def upload(bytes, filename: "goodreads_library_export.csv")
          Rack::Test::UploadedFile.new(StringIO.new(bytes), "text/csv", original_filename: filename)
        end

        def export
          goodreads_csv({"Book Id" => "656", "Title" => "War and Peace", "Author" => "Leo Tolstoy", "Exclusive Shelf" => "read"})
        end

        test "a Goodreads export passes with its bytes, rows and filename" do
          result = ValidateUpload.call(user: @user, upload: upload(export))

          assert result.success?
          assert_equal 1, result.data[:rows].size
          assert_equal "goodreads_library_export.csv", result.data[:filename]
          assert_equal export.b, result.data[:bytes]
        end

        test "no file is refused" do
          assert_not ValidateUpload.call(user: @user, upload: nil).success?
        end

        test "a file over the size limit is refused unread" do
          with_goodreads_import_config(max_file_bytes: 10) do
            result = ValidateUpload.call(user: @user, upload: upload(export))

            assert_not result.success?
          end
        end

        test "an xlsx renamed .csv is refused" do
          bytes = "PK\x03\x04\x14\x00\x06\x00".b + SecureRandom.random_bytes(200)

          assert_not ValidateUpload.call(user: @user, upload: upload(bytes)).success?
        end

        test "a csv without the export headers is refused" do
          assert_not ValidateUpload.call(user: @user, upload: upload("Title,Author\nDune,Frank Herbert\n")).success?
        end

        test "an export with no rows is refused" do
          assert_not ValidateUpload.call(user: @user, upload: upload(goodreads_csv)).success?
        end

        test "an import in progress refuses another" do
          @user.goodreads_imports.create!(status: :resolving)

          assert_not ValidateUpload.call(user: @user, upload: upload(export)).success?
        end

        test "the daily limit counts member imports from the last 24 hours" do
          with_goodreads_import_config(daily_limit: 2) do
            @user.goodreads_imports.create!(status: :complete, created_at: 25.hours.ago)
            @user.goodreads_imports.create!(status: :complete)
            @user.goodreads_imports.create!(status: :failed, source: :legacy_replay, legacy_import_id: 991)
            assert ValidateUpload.call(user: @user, upload: upload(export)).success?

            @user.goodreads_imports.create!(status: :failed)
            assert_not ValidateUpload.call(user: @user, upload: upload(export)).success?
          end
        end

        def with_goodreads_import_config(**overrides)
          config = Rails.application.config.x.goodreads_imports
          saved = overrides.keys.index_with { |key| config[key] }
          overrides.each { |key, value| config[key] = value }
          yield
        ensure
          saved.each { |key, value| config[key] = value }
        end
      end
    end
  end
end
