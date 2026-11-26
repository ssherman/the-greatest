require "test_helper"

class Books::GoodreadsReimport::SnapshotJobTest < ActiveSupport::TestCase
  setup do
    @path = Pathname.new(Dir.mktmpdir).join("counts.json")
    Services::Books::GoodreadsReimport::Report.stubs(:snapshot_path).returns(@path)
    Rails.configuration.x.goodreads_reimport.stubs(:enabled).returns(false)
  end

  test "writes the snapshot file with the gate off" do
    Books::GoodreadsReimport::SnapshotJob.new.perform

    assert_predicate @path, :exist?
    assert JSON.parse(@path.read).key?("users")
  end

  test "refuses to overwrite an existing snapshot unless redo" do
    @path.write("old")
    Rails.logger.expects(:warn).with { |line| line.include?("already exists") }

    Books::GoodreadsReimport::SnapshotJob.new.perform

    assert_equal "old", @path.read

    Books::GoodreadsReimport::SnapshotJob.new.perform(true)

    assert JSON.parse(@path.read).key?("users")
  end

  test "new_pass writes a further file and leaves the existing one alone" do
    dir = @path.dirname
    Services::Books::GoodreadsReimport::Report.unstub(:snapshot_path)
    Services::Books::GoodreadsReimport::Report.stubs(:storage_dir).returns(dir)
    @path.write("old")

    Books::GoodreadsReimport::SnapshotJob.new.perform(false, true)

    assert_equal "old", @path.read
    assert_equal 1, dir.glob("counts-*.json").size
  end
end
