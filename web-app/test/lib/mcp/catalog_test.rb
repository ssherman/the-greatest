require "test_helper"

module Mcp
  class CatalogTest < ActiveSupport::TestCase
    def components
      {
        "parameters" => {
          "page" => {"name" => "page", "in" => "query", "description" => "1-based page number.",
                     "schema" => {"type" => "integer", "minimum" => 1, "default" => 1}},
          "per_page" => {"name" => "per_page", "in" => "query",
                         "schema" => {"type" => "integer", "minimum" => 1, "maximum" => 100, "default" => 50}},
          "id" => {"name" => "id", "in" => "path", "required" => true, "description" => "The widget's id.",
                   "schema" => {"$ref" => "#/components/schemas/Id"}}
        },
        "schemas" => {
          "Id" => {"type" => "integer", "minimum" => 1},
          "Color" => {"type" => "string", "enum" => %w[red blue]},
          "WidgetInput" => {
            "type" => "object",
            "required" => ["name"],
            "properties" => {
              "name" => {"type" => "string", "minLength" => 1},
              "color" => {"$ref" => "#/components/schemas/Color"}
            }
          }
        }
      }
    end

    def read_scope = [{"bearerAuth" => ["books:read"]}]

    def write_scope = [{"bearerAuth" => ["books:admin:write"]}]

    def mcp(description: "Lists the widgets, newest first. Use this to browse; prefer get_widget for one widget.", **extra)
      {"description" => description}.merge(extra.stringify_keys)
    end

    def list_widgets
      {"operationId" => "listWidgets", "summary" => "Widgets", "security" => read_scope, "x-mcp" => mcp,
       "parameters" => [
         {"$ref" => "#/components/parameters/page"},
         {"$ref" => "#/components/parameters/per_page"},
         {"name" => "q", "in" => "query", "required" => true, "description" => "Search text.", "schema" => {"type" => "string"}}
       ]}
    end

    def get_widget
      {"operationId" => "getWidget", "summary" => "One widget", "security" => read_scope,
       "x-mcp" => mcp(description: "Returns one widget by id, with its color. Use after list_widgets."),
       "parameters" => [{"$ref" => "#/components/parameters/id"}]}
    end

    def update_widget
      {"operationId" => "updateWidget", "summary" => "Update a widget", "security" => write_scope,
       "x-mcp" => mcp(description: "Changes a widget's name or color."),
       "parameters" => [{"$ref" => "#/components/parameters/id"}],
       "requestBody" => {"required" => true, "content" => {"application/json" => {"schema" => {"$ref" => "#/components/schemas/WidgetInput"}}}}}
    end

    def delete_widget
      {"operationId" => "deleteWidget", "summary" => "Delete a widget", "security" => write_scope,
       "x-mcp" => mcp(description: "Permanently deletes a widget.", destructive: true),
       "parameters" => [{"$ref" => "#/components/parameters/id"}]}
    end

    def create_widget
      {"operationId" => "createWidget", "summary" => "Create a widget", "security" => write_scope,
       "x-mcp" => mcp(description: "Creates a widget.", name: "make_widget"),
       "requestBody" => {"content" => {"application/json" => {"schema" => {"$ref" => "#/components/schemas/WidgetInput"}}}}}
    end

    def document
      {
        "paths" => {
          "/api/v1/openapi.json" => {"get" => {"operationId" => "getOpenapi", "summary" => "This document", "security" => []}},
          "/api/v1/widgets" => {"get" => list_widgets, "post" => create_widget},
          "/api/v1/widgets/{id}" => {"get" => get_widget, "put" => update_widget, "delete" => delete_widget}
        },
        "components" => components
      }
    end

    def catalog = Mcp::Catalog.new(document)

    def schema_of(operation_id) = catalog.fetch(operation_id).input_schema

    test "one tool per x-mcp operation and none for an operation without one" do
      assert_equal %w[createWidget deleteWidget getWidget listWidgets updateWidget], catalog.operations.map(&:operation_id).sort
      assert_raises(KeyError) { catalog.fetch("getOpenapi") }
    end

    test "the default tool name is the snake-cased operationId and x-mcp.name overrides it" do
      assert_equal "list_widgets", catalog.fetch("listWidgets").tool_name
      assert_equal "make_widget", catalog.fetch("createWidget").tool_name
      assert_equal "make_widget", catalog.tool("createWidget").name_value
    end

    test "title is the summary and description is the x-mcp description" do
      operation = catalog.fetch("getWidget")

      assert_equal "One widget", operation.title
      assert_equal "Returns one widget by id, with its color. Use after list_widgets.", operation.description
      assert_equal operation.description, catalog.tool("getWidget").description_value
      assert_equal "One widget", catalog.tool("getWidget").title_value
    end

    test "every ref in the input schema is resolved inline" do
      schema = schema_of("updateWidget")

      refute_includes schema.to_s, "$ref"
      assert_equal({"type" => "integer", "minimum" => 1, "description" => "The widget's id."}, schema["properties"]["id"])
      assert_equal %w[red blue], schema["properties"]["color"]["enum"]
    end

    test "per_page is exposed as limit with its bounds and default" do
      operation = catalog.fetch("listWidgets")
      limit = operation.input_schema["properties"]["limit"]

      assert_equal [1, 100, 50], limit.values_at("minimum", "maximum", "default")
      assert_nil operation.input_schema["properties"]["per_page"]
      assert_equal "per_page", operation.arguments["limit"].wire_name
      assert_equal :query, operation.arguments["limit"].location
      assert_equal "page", operation.arguments["page"].wire_name
    end

    test "required lists path parameters and required query parameters" do
      assert_equal ["q"], schema_of("listWidgets")["required"]
      assert_equal ["id"], schema_of("getWidget")["required"]
    end

    test "a body's required members join the path parameters in required" do
      assert_equal %w[id name], schema_of("updateWidget")["required"]
    end

    test "required is omitted when nothing is required" do
      source = document
      source["paths"]["/api/v1/widgets"]["get"]["parameters"] = [{"$ref" => "#/components/parameters/page"}]

      refute Mcp::Catalog.new(source).fetch("listWidgets").input_schema.key?("required")
    end

    test "the schema is a strict object" do
      schema = schema_of("listWidgets")

      assert_equal "object", schema["type"]
      assert_equal false, schema["additionalProperties"]
    end

    test "body properties are flattened next to the path parameter" do
      operation = catalog.fetch("updateWidget")

      assert_equal %w[color id name], operation.input_schema["properties"].keys.sort
      assert_equal :body, operation.arguments["name"].location
      assert_equal :path, operation.arguments["id"].location
      assert_equal "name", operation.arguments["name"].wire_name
    end

    test "a path-item parameter is part of every operation under it" do
      source = document
      item = source["paths"]["/api/v1/widgets/{id}"]
      item["parameters"] = item["get"].delete("parameters")
      item["put"].delete("parameters")
      item["delete"].delete("parameters")
      built = Mcp::Catalog.new(source)

      assert_equal :path, built.fetch("getWidget").arguments["id"].location
      assert_equal ["id"], built.fetch("deleteWidget").input_schema["required"]
    end

    test "an operation parameter overrides a path-item parameter of the same name and location" do
      source = document
      item = source["paths"]["/api/v1/widgets/{id}"]
      item["parameters"] = [{"name" => "id", "in" => "path", "required" => true, "schema" => {"type" => "string"}}]
      built = Mcp::Catalog.new(source)

      assert_equal "integer", built.fetch("getWidget").input_schema["properties"]["id"]["type"]
    end

    test "the same argument name from a query parameter and the body fails generation naming both" do
      source = document
      source["paths"]["/api/v1/widgets"]["post"]["parameters"] = [
        {"name" => "name", "in" => "query", "schema" => {"type" => "string"}}
      ]
      error = assert_raises(Mcp::Catalog::GenerationError) { Mcp::Catalog.new(source) }

      assert_includes error.message, "createWidget"
      assert_includes error.message, "query"
      assert_includes error.message, "body"
    end

    test "a query parameter named limit collides with the renamed per_page" do
      source = document
      source["paths"]["/api/v1/widgets"]["get"]["parameters"] << {"name" => "limit", "in" => "query", "schema" => {"type" => "integer"}}

      error = assert_raises(Mcp::Catalog::GenerationError) { Mcp::Catalog.new(source) }
      assert_includes error.message, "limit"
    end

    test "a missing description fails generation naming the operation" do
      source = document
      source["paths"]["/api/v1/widgets/{id}"]["get"]["x-mcp"] = {}

      error = assert_raises(Mcp::Catalog::GenerationError) { Mcp::Catalog.new(source) }
      assert_includes error.message, "getWidget"
    end

    test "an x-mcp operation with no scope fails generation" do
      source = document
      source["paths"]["/api/v1/widgets/{id}"]["get"]["security"] = []

      error = assert_raises(Mcp::Catalog::GenerationError) { Mcp::Catalog.new(source) }
      assert_includes error.message, "getWidget"
    end

    test "an unresolvable ref fails generation" do
      source = document
      source["paths"]["/api/v1/widgets/{id}"]["get"]["parameters"] = [{"$ref" => "#/components/parameters/nope"}]

      assert_raises(Mcp::Catalog::GenerationError) { Mcp::Catalog.new(source) }
    end

    test "a GET is read-only, idempotent and not destructive" do
      hints = catalog.tool("getWidget").annotations_value.to_h

      assert_equal({destructiveHint: false, idempotentHint: true, openWorldHint: false, readOnlyHint: true, title: "One widget"}, hints)
    end

    test "a POST that is not destructive is neither read-only nor idempotent" do
      hints = catalog.tool("createWidget").annotations_value.to_h

      assert_equal({destructiveHint: false, idempotentHint: false, openWorldHint: false, readOnlyHint: false, title: "Create a widget"}, hints)
    end

    test "a DELETE marked destructive is idempotent and destructive" do
      hints = catalog.tool("deleteWidget").annotations_value.to_h

      assert_equal({destructiveHint: true, idempotentHint: true, openWorldHint: false, readOnlyHint: false, title: "Delete a widget"}, hints)
      assert catalog.fetch("deleteWidget").destructive
      refute catalog.fetch("getWidget").destructive
    end

    test "a PUT is idempotent and a PATCH is not" do
      source = document
      source["paths"]["/api/v1/widgets/{id}"]["patch"] = update_widget.merge("operationId" => "patchWidget", "x-mcp" => mcp)
      built = Mcp::Catalog.new(source)

      assert_equal true, built.tool("updateWidget").annotations_value.idempotent_hint
      assert_equal false, built.tool("patchWidget").annotations_value.idempotent_hint
    end

    test "tools_for keeps the tools whose scope the principal satisfies" do
      reader = ::Api::Principal.new(scopes: ["books:read"])
      writer = ::Api::Principal.new(scopes: ["books:admin:write"])

      assert_equal %w[get_widget list_widgets], catalog.tools_for(reader).map(&:name_value).sort
      assert_equal 5, catalog.tools_for(writer).size
      assert_empty catalog.tools_for(::Api::Principal.new(scopes: ["music:read"]))
    end

    test "a tool call runs the dispatcher with the server context's principal and request" do
      principal = ::Api::Principal.new(scopes: ["books:read"])
      request = Object.new
      built = catalog
      operation = built.fetch("getWidget")
      response = ::Mcp::Dispatcher::Response.new(status: 200, body: {"data" => {"id" => 3}, "links" => {}})
      ::Mcp::Dispatcher.expects(:call).with(operation, {id: 3}, principal: principal, request: request).returns(response)

      result = built.tool("getWidget").call(id: 3, server_context: {principal: principal, request: request})

      assert_equal false, result.to_h[:isError]
      assert_equal({"data" => {"id" => 3}}, JSON.parse(result.to_h[:content].first[:text]))
    end

    test "for memoises per document and domain outside development" do
      assert_same Mcp::Catalog.for(document: :public, domain: :books), Mcp::Catalog.for(document: :public, domain: :books)
    end

    test "for rebuilds on every call in development" do
      Rails.env.stubs(:development?).returns(true)

      refute_same Mcp::Catalog.for(document: :public, domain: :books), Mcp::Catalog.for(document: :public, domain: :books)
    end

    class PublicDocumentTest < ActiveSupport::TestCase
      def catalog = Mcp::Catalog.for(document: :public, domain: :books)

      test "every public operation but getOpenapi is a tool" do
        expected = ::Api::OpenapiDocument.operations(::Api::OpenapiDocument.raw(:public)).map(&:operation_id) - ["getOpenapi"]

        assert_equal expected.sort, catalog.operations.map(&:operation_id).sort
      end

      test "no admin path is in the public catalogue" do
        assert catalog.operations.none? { |operation| operation.path.start_with?("/api/v1/admin") }
      end

      test "every input schema is valid JSON Schema 2020-12" do
        catalog.operations.each do |operation|
          errors = JSONSchemer.validate_schema(operation.input_schema).to_a

          assert_empty errors, "#{operation.operation_id}: #{errors.first&.fetch("error", nil)}"
          assert_equal operation.input_schema, catalog.tool(operation.operation_id).input_schema_value.to_h.deep_stringify_keys.except("$schema")
        end
      end

      test "no input schema leaves a ref behind" do
        catalog.operations.each { |operation| refute_includes operation.input_schema.to_s, "$ref", operation.operation_id }
      end

      test "tool names are unique" do
        names = catalog.operations.map(&:tool_name)

        assert_equal names.uniq, names
      end

      test "tools_for filters by scope" do
        assert_equal catalog.operations.size, catalog.tools_for(::Api::Principal.new(scopes: ["books:read"])).size
        assert_empty catalog.tools_for(::Api::Principal.new(scopes: ["music:read"]))
      end

      test "every description is written for a model" do
        catalog.operations.each do |operation|
          assert_operator operation.description.length, :>=, 60, operation.operation_id
          refute_equal operation.title, operation.description, operation.operation_id
        end
      end

      test "every tool exposes limit and never per_page" do
        catalog.operations.each do |operation|
          refute operation.input_schema["properties"].key?("per_page"), operation.operation_id
          refute operation.arguments.key?("per_page"), operation.operation_id
        end
      end

      test "the music host's catalogue has no tool" do
        assert_empty Mcp::Catalog.for(document: :public, domain: :music).operations
      end
    end
  end
end
