# frozen_string_literal: true

require "test_helper"

module Books
  module PublisherIntake
    class JsonLdTest < ActiveSupport::TestCase
      def fixture_html(name) = file_fixture("publisher_intake/shared/#{name}").read

      def script(json) = %(<html><script type="application/ld+json">#{json}</script></html>)

      test "finds a top-level Book and skips an earlier script that is not valid JSON" do
        nodes = JsonLd.nodes(fixture_html("json_ld_book.html"), types: ["Book"])

        assert_equal ["Top Level"], nodes.map { |n| n["name"] }
      end

      test "finds a Book inside @graph and ignores other types" do
        nodes = JsonLd.nodes(script('{"@graph":[{"@type":"WebPage"},{"@type":"Book","name":"In Graph"}]}'), types: ["Book"])

        assert_equal ["In Graph"], nodes.map { |n| n["name"] }
      end

      test "matches @type given as an array" do
        nodes = JsonLd.nodes(fixture_html("json_ld_graph.html"), types: ["Product"])

        assert_equal ["Multi Type"], nodes.map { |n| n["name"] }
      end

      test "returns nested workExample books when types include Book" do
        nodes = JsonLd.nodes(fixture_html("json_ld_graph.html"), types: ["Book"])

        assert_equal ["Multi Type", "Hardcover Edition", "Paperback Edition"], nodes.map { |n| n["name"] }
      end

      test "no JSON-LD gives an empty array" do
        assert_equal [], JsonLd.nodes("<html><body>Nothing</body></html>", types: ["Book"])
      end
    end
  end
end
