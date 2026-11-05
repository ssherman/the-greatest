require "test_helper"

module Api
  class OpenapiDocumentTest < ActiveSupport::TestCase
    test "operations lists a document's operations with their method and path" do
      operations = ::Api::OpenapiDocument.operations(::Api::OpenapiDocument.raw(:public))
      search = operations.find { |op| op.operation_id == "searchBooks" }

      assert_equal ["get", "/api/v1/search/books"], [search.http_method, search.path]
      assert_equal "books:read", search.scope
    end

    test "operations skips path-item keys that are not HTTP methods" do
      %i[public admin].each do |document|
        operations = ::Api::OpenapiDocument.operations(::Api::OpenapiDocument.raw(document))

        assert operations.any?
        assert_empty operations.map(&:http_method) - %w[get put post delete patch]
      end
    end

    test "operations accepts the host-tailored document" do
      source = ::Api::OpenapiDocument.for_host("https://example.test", domain: :music)
      paths = ::Api::OpenapiDocument.operations(source).map(&:path)

      assert_includes paths, "/api/v1/openapi.json"
      assert_not_includes paths, "/api/v1/books"
    end

    test "scope is nil for empty security" do
      op = ::Api::OpenapiDocument::Operation.new(http_method: "get", path: "/x", operation_id: "x", path_item: {}, definition: {"security" => []})

      assert_nil op.scope
    end

    test "scope refuses a security requirement it cannot reduce to one scope" do
      two_scopes = {"security" => [{"bearerAuth" => ["a", "b"]}]}
      two_requirements = {"security" => [{"bearerAuth" => ["a"]}, {"bearerAuth" => ["b"]}]}

      [two_scopes, two_requirements].each do |definition|
        op = ::Api::OpenapiDocument::Operation.new(http_method: "get", path: "/x", operation_id: "x", path_item: {}, definition: definition)

        assert_raises(ArgumentError) { op.scope }
      end
    end
  end
end
