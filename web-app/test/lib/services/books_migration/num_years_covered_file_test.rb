require "test_helper"
require "tmpdir"

class Services::BooksMigration::NumYearsCoveredFileTest < ActiveSupport::TestCase
  F = Services::BooksMigration::NumYearsCoveredFile
  Entry = Services::BooksMigration::NumYearsCoveredDeriver::Entry

  setup do
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "num_years_covered.yml")
  end

  teardown { FileUtils.remove_entry(@dir) }

  def entry(id, years, name = "List #{id}")
    Entry.new(id: id, years: years, name: name, bucket: 25, reason: "unparsed", flags: [])
  end

  test "load returns an empty hash when the file does not exist" do
    assert_equal({}, F.load(@path))
  end

  test "load returns integer ids to integer years, ignoring comments" do
    File.write(@path, "# header\n1893: 24   # a list  (25 -> reason)\n42: 100\n")
    assert_equal({1893 => 24, 42 => 100}, F.load(@path))
  end

  test "load raises naming a non-positive-integer entry" do
    File.write(@path, "1893: 0\n")
    error = assert_raises(ArgumentError) { F.load(@path) }
    assert_match(/1893/, error.message)

    File.write(@path, "1893: twenty\n")
    assert_raises(ArgumentError) { F.load(@path) }
  end

  test "append creates the file with the header and the entries" do
    result = F.append([entry(1, 10), entry(2, 20)], @path)

    assert_equal({kept: 0, added: 2}, result)
    content = File.read(@path)
    assert content.start_with?("# Books lists: number of publication years"), content
    assert_equal({1 => 10, 2 => 20}, F.load(@path))
  end

  test "append keeps existing lines verbatim and adds only new ids" do
    F.append([entry(1, 10)], @path)
    File.write(@path, File.read(@path).sub("1: 10", "1: 12   # reviewed by hand"))

    result = F.append([entry(1, 99), entry(3, 30)], @path)

    assert_equal({kept: 1, added: 1}, result)
    assert_includes File.read(@path), "1: 12   # reviewed by hand"
    assert_equal({1 => 12, 3 => 30}, F.load(@path))
  end

  test "append with nothing new leaves the file byte-identical" do
    F.append([entry(1, 10)], @path)
    before = File.read(@path)

    assert_equal({kept: 1, added: 0}, F.append([entry(1, 10)], @path))
    assert_equal before, File.read(@path)
  end
end
