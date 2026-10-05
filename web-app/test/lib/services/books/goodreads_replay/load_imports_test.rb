require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      class LoadImportsTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        setup do
          @user = users(:regular_user)
          @csv = goodreads_csv(
            {"Book Id" => "1001", "Title" => "The Quiet Year", "Author" => "Anna Brenner", "Exclusive Shelf" => "read"},
            {"Book Id" => "1002", "Title" => "Loud Days (Noise, #2)", "Author" => "Bo Lind", "Exclusive Shelf" => "to-read"}
          )
          @downloads = []
        end

        def legacy(**attributes)
          LoadImports::LegacyImport.new(id: 501, user_id: @user.id, status: "complete", error: nil,
            blob_key: "legacy-key-501", content_type: "text/csv", filename: "goodreads_library_export.csv", **attributes)
        end

        def load(*imports, bytes: @csv)
          LoadImports.call(legacy_imports: imports, download: ->(key) {
            @downloads << key
            bytes
          })
        end

        test "a completed legacy import becomes a complete replay import owned by the same user, with its file and rows" do
          result = load(legacy)

          import = ::Books::GoodreadsImport.find_by!(legacy_import_id: 501)
          assert_equal({loaded: 1}, result.data[:tally])
          assert_predicate import, :legacy_replay?
          assert_predicate import, :complete?
          assert_equal @user, import.user
          assert_equal @csv, import.file.download
          assert_equal [1, 2], import.rows.order(:row_number).pluck(:row_number)
          assert_equal 2, import.editions_count
        end

        test "loading twice downloads once and writes nothing new" do
          load(legacy)
          load(legacy)

          assert_equal ["legacy-key-501"], @downloads
          assert_equal 1, ::Books::GoodreadsImport.where(legacy_import_id: 501).count
          assert_equal 2, ::Books::GoodreadsImport.find_by!(legacy_import_id: 501).rows.count
        end

        test "after the rows are gone (a re-migration truncated them) the kept file is parsed again" do
          load(legacy)
          import = ::Books::GoodreadsImport.find_by!(legacy_import_id: 501)
          import.rows.delete_all

          load(legacy)

          assert_equal ["legacy-key-501"], @downloads
          assert_equal 2, import.rows.count
        end

        test "a failed or stuck legacy import is loaded failed, with the legacy reason, its file and its rows" do
          load(legacy(status: "failed", error: "CSV::MalformedCSVError: Illegal quoting"), legacy(id: 502, status: "pending"))

          failed = ::Books::GoodreadsImport.find_by!(legacy_import_id: 501)
          stuck = ::Books::GoodreadsImport.find_by!(legacy_import_id: 502)
          assert_predicate failed, :failed?
          assert_equal "legacy import failed: CSV::MalformedCSVError: Illegal quoting", failed.error
          assert_equal "legacy import never finished (pending)", stuck.error
          assert_equal 2, failed.rows.count
          assert failed.file.attached?
        end

        test "a non-CSV upload is marked failed and never downloaded" do
          result = load(legacy(content_type: "video/mp4", filename: "clip.mp4"))

          import = ::Books::GoodreadsImport.find_by!(legacy_import_id: 501)
          assert_equal({not_csv: 1}, result.data[:tally])
          assert_predicate import, :failed?
          assert_equal "not a CSV upload: video/mp4", import.error
          assert_empty @downloads
          refute import.file.attached?
        end

        test "a CSV that is not a Goodreads export is kept, failed with the parser's reason, and has no rows" do
          result = load(legacy, bytes: "name,age\nbob,4\n")

          import = ::Books::GoodreadsImport.find_by!(legacy_import_id: 501)
          assert_equal({unreadable: 1}, result.data[:tally])
          assert_predicate import, :failed?
          assert_match(/\Alegacy upload unreadable: missing Goodreads export headers/, import.error)
          assert_equal 0, import.rows.count
        end

        test "a Windows-1252 file loads with its accents" do
          bytes = goodreads_csv({"Book Id" => "1003", "Title" => "Café Society", "Author" => "Zoë Ågren", "Exclusive Shelf" => "read"})
            .encode(Encoding::Windows_1252)

          load(legacy, bytes: bytes)

          assert_equal "Café Society", ::Books::GoodreadsImport.find_by!(legacy_import_id: 501).editions.first.title
        end

        test "an import whose user is gone from the new app is counted and skipped; the rest still load" do
          result = load(legacy(user_id: 0), legacy(id: 502))

          assert_equal({missing_user: 1, loaded: 1}, result.data[:tally])
          assert_nil ::Books::GoodreadsImport.find_by(legacy_import_id: 501)
          assert ::Books::GoodreadsImport.exists?(legacy_import_id: 502)
        end

        test "a blob the legacy bucket no longer has fails that import only; the rest still load" do
          download = ->(key) { (key == "gone") ? raise(LoadImports::MissingBlob, "gone") : @csv }

          result = LoadImports.call(legacy_imports: [legacy(blob_key: "gone"), legacy(id: 502)], download: download)

          missing = ::Books::GoodreadsImport.find_by!(legacy_import_id: 501)
          assert_equal({missing_file: 1, loaded: 1}, result.data[:tally])
          assert_predicate missing, :failed?
          assert_equal "legacy upload is missing from the legacy bucket (key gone)", missing.error
          refute missing.file.attached?
          assert_equal 2, ::Books::GoodreadsImport.find_by!(legacy_import_id: 502).rows.count
        end

        test "the legacy bucket's NoSuchKey becomes MissingBlob" do
          r2 = ::Services::BooksMigration::LegacyR2 # loads aws-sdk-s3 (require: false in the Gemfile)
          client = mock("legacy_r2")
          client.stubs(:get_object).raises(Aws::S3::Errors::NoSuchKey.new(nil, "The specified key does not exist."))
          r2.stubs(:client).returns(client)
          r2.stubs(:bucket).returns("legacy-bucket")

          result = LoadImports.call(legacy_imports: [legacy])

          assert_equal({missing_file: 1}, result.data[:tally])
        end

        test "a legacy import with no blob is counted and left unattached" do
          result = load(legacy(blob_key: nil))

          assert_equal({missing_file: 1}, result.data[:tally])
          assert_empty @downloads
        end
      end
    end
  end
end
