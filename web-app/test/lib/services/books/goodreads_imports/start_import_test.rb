require "test_helper"

module Services
  module Books
    module GoodreadsImports
      class StartImportTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        setup do
          @user = User.create!(email: "starter@example.com", role: :user, email_verified: false)
          @bytes = goodreads_csv({"Book Id" => "656", "Title" => "War and Peace", "Author" => "Leo Tolstoy", "Exclusive Shelf" => "read"})
        end

        def upload(bytes)
          Rack::Test::UploadedFile.new(StringIO.new(bytes), "text/csv", original_filename: "export.csv")
        end

        test "a valid upload makes a queued member import with the file and queues the job" do
          ::Books::Goodreads::RunImportJob.expects(:perform_async).with { |id| id.is_a?(Integer) }

          result = StartImport.call(user: @user, upload: upload(@bytes))

          import = result.data[:import]
          assert result.success?
          assert_equal %w[member queued], [import.source, import.status]
          assert_equal @bytes.b, import.file.download
        end

        test "a refused upload makes no import and queues nothing" do
          ::Books::Goodreads::RunImportJob.expects(:perform_async).never

          assert_no_difference -> { ::Books::GoodreadsImport.count } do
            assert_not StartImport.call(user: @user, upload: upload("not,a,goodreads\nfile,,\n")).success?
          end
        end

        test "losing the in-progress race is refused, not raised" do
          ValidateUpload.stubs(:call).returns(ValidateUpload::Result.new(success?: true,
            data: {bytes: @bytes, rows: [], filename: "export.csv"}, errors: []))
          @user.goodreads_imports.create!(status: :parsing)
          ::Books::Goodreads::RunImportJob.expects(:perform_async).never

          assert_not StartImport.call(user: @user, upload: upload(@bytes)).success?
        end
      end
    end
  end
end
