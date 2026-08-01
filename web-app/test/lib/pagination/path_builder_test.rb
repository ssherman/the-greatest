require "test_helper"

module Pagination
  class PathBuilderTest < ActiveSupport::TestCase
    test "page one returns the base path unchanged" do
      builder = Pagination::PathBuilder.new(base_path: "/albums")

      assert_equal "/albums", builder.call(1)
    end

    test "page zero and negatives collapse to the base path" do
      builder = Pagination::PathBuilder.new(base_path: "/albums")

      assert_equal "/albums", builder.call(0)
      assert_equal "/albums", builder.call(-3)
    end

    test "appends the page segment for later pages" do
      builder = Pagination::PathBuilder.new(base_path: "/albums")

      assert_equal "/albums/page/2", builder.call(2)
      assert_equal "/albums/page/243", builder.call(243)
    end

    test "handles the root path without doubling the slash" do
      builder = Pagination::PathBuilder.new(base_path: "/")

      assert_equal "/", builder.call(1)
      assert_equal "/page/2", builder.call(2)
    end

    test "strips a trailing slash from the base path" do
      builder = Pagination::PathBuilder.new(base_path: "/albums/")

      assert_equal "/albums", builder.call(1)
      assert_equal "/albums/page/2", builder.call(2)
    end

    test "accepts a string page number" do
      builder = Pagination::PathBuilder.new(base_path: "/albums")

      assert_equal "/albums/page/5", builder.call("5")
    end

    test "from_request replaces an existing page segment rather than appending" do
      builder = Pagination::PathBuilder.from_request(fake_request("/albums/page/7"))

      assert_equal "/albums", builder.base_path
      assert_equal "/albums/page/8", builder.call(8)
    end

    test "from_request keeps nested filter and scope segments" do
      builder = Pagination::PathBuilder.from_request(fake_request("/rc/12/albums/since/1990"))

      assert_equal "/rc/12/albums/since/1990/page/2", builder.call(2)
    end

    test "from_request only strips a page segment at the end" do
      builder = Pagination::PathBuilder.from_request(fake_request("/lists/page/3/page/4"))

      assert_equal "/lists/page/3", builder.base_path
    end

    test "from_request moves a format suffix to the end when there is no page segment" do
      builder = Pagination::PathBuilder.from_request(fake_request("/albums.html", format: "html"))

      assert_equal "/albums", builder.base_path
      assert_equal "/albums/page/2.html", builder.call(2)
    end

    test "from_request replaces the page segment and keeps the format suffix at the end" do
      builder = Pagination::PathBuilder.from_request(fake_request("/albums/page/2.html", format: "html"))

      assert_equal "/albums", builder.base_path
      assert_equal "/albums/page/3.html", builder.call(3)
    end

    test "from_request drops the page segment but keeps the format suffix for page 1" do
      builder = Pagination::PathBuilder.from_request(fake_request("/albums/page/2.html", format: "html"))

      assert_equal "/albums.html", builder.call(1)
    end

    test "from_request with no format behaves exactly as before" do
      builder = Pagination::PathBuilder.from_request(fake_request("/albums/page/2"))

      assert_nil builder.instance_variable_get(:@format)
      assert_equal "/albums", builder.base_path
      assert_equal "/albums/page/3", builder.call(3)
      assert_equal "/albums", builder.call(1)
    end

    private

    def fake_request(path, format: nil)
      Struct.new(:path, :path_parameters).new(path, {format: format}.compact)
    end
  end
end
