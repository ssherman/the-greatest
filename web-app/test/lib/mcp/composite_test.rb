require "test_helper"

module Mcp
  class CompositeTest < ActiveSupport::TestCase
    class Sample < Mcp::Composite
      operations "getBook"
    end

    class TwoReads < Mcp::Composite
      operations "listWidgets", "getWidget"

      def self.tool_name = "two_reads"

      def self.title = "Two reads"

      def self.description = "Reads two things."

      def self.input_schema = {"type" => "object", "properties" => {}}
    end

    class ReadAndMerge < TwoReads
      operations "getWidget", "mergeWidgets"

      def self.tool_name = "read_and_merge"
    end

    def catalog = Mcp::Catalog.for(document: :public, domain: :books)

    def widget_operation(id, **x_mcp)
      {"operationId" => id, "summary" => id, "security" => [{"bearerAuth" => ["books:read"]}],
       "x-mcp" => {"description" => "Does #{id}."}.merge(x_mcp.stringify_keys)}
    end

    def widget_catalog
      Mcp::Catalog.new(
        "paths" => {
          "/api/v1/widgets" => {"get" => widget_operation("listWidgets")},
          "/api/v1/widgets/one" => {"get" => widget_operation("getWidget")},
          "/api/v1/widgets/merge" => {"post" => widget_operation("mergeWidgets", destructive: true)}
        }
      )
    end

    test "operations declares the ids and operation_ids reads them" do
      assert_equal ["getBook"], Sample.operation_ids
      assert_equal [], Class.new(Mcp::Composite).operation_ids
    end

    test "dispatch refuses an operation the composite did not declare" do
      assert_raises(ArgumentError) do
        Sample.dispatch(catalog, "listBooks", {}, principal: nil, request: nil)
      end
    end

    test "a composite over two GETs is read-only, idempotent and not destructive" do
      hints = TwoReads.tool(widget_catalog).annotations_value.to_h

      assert_equal({readOnlyHint: true, idempotentHint: true, destructiveHint: false, openWorldHint: false, title: "Two reads"}, hints)
    end

    test "a composite that includes a destructive POST is none of read-only or idempotent, and is destructive" do
      hints = ReadAndMerge.tool(widget_catalog).annotations_value.to_h

      assert_equal({readOnlyHint: false, idempotentHint: false, destructiveHint: true, openWorldHint: false, title: "Two reads"}, hints)
    end

    test "find_book keeps its read-only hints, derived from the GETs it calls" do
      hints = Mcp::Sites::Books::FindBook.tool(catalog).annotations_value

      assert_equal [true, true, false, false], [hints.read_only_hint, hints.idempotent_hint, hints.destructive_hint, hints.open_world_hint]
    end

    test "run must be implemented by a subclass" do
      assert_raises(NotImplementedError) { Sample.run(catalog, {}, principal: nil, request: nil) }
    end
  end
end
