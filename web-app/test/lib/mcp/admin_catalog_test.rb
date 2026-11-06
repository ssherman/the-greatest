require "test_helper"

module Mcp
  class AdminCatalogTest < ActiveSupport::TestCase
    DESTRUCTIVE = %w[mergeCategories mergeBook mergeAuthor deleteAdminCategory untagBook untagAuthor].freeze

    def catalog = Mcp::Catalog.for(document: :admin, domain: :books)

    def tool_named(name) = catalog.operations.find { |operation| operation.tool_name == name }

    test "every admin operation but getAdminOpenapi is a tool" do
      expected = ::Api::OpenapiDocument.operations(::Api::OpenapiDocument.raw(:admin)).map(&:operation_id) - ["getAdminOpenapi"]

      assert_equal 14, expected.size
      assert_equal expected.sort, catalog.operations.map(&:operation_id).sort
    end

    test "the admin tools have the expected names" do
      expected = %w[search_admin_books search_admin_authors search_admin_categories create_admin_category
        get_admin_category update_admin_category delete_admin_category merge_categories merge_book
        merge_author tag_book untag_book tag_author untag_author]

      assert_equal expected.sort, catalog.operations.map(&:tool_name).sort
    end

    test "exactly the merges and DELETEs are destructive" do
      destructive = catalog.operations.select(&:destructive).map(&:operation_id)

      assert_equal DESTRUCTIVE.sort, destructive.sort
    end

    test "every input schema is valid JSON Schema 2020-12" do
      catalog.operations.each do |operation|
        errors = JSONSchemer.validate_schema(operation.input_schema).to_a

        assert_empty errors, "#{operation.operation_id}: #{errors.first&.fetch("error", nil)}"
        assert_equal operation.input_schema, catalog.tool(operation.operation_id).input_schema_value.to_h.deep_stringify_keys.except("$schema")
      end
    end

    test "body and path arguments are flattened" do
      tag = tool_named("tag_book")
      assert_equal [:path, :body], [tag.arguments["id"].location, tag.arguments["category_id"].location]
      assert_equal %w[category_id id], tag.input_schema["required"].sort

      untag = tool_named("untag_book")
      assert_equal [:path, :path], [untag.arguments["id"].location, untag.arguments["category_id"].location]
      assert_equal %w[category_id id], untag.input_schema["required"].sort

      assert_equal :query, tool_named("delete_admin_category").arguments["dry_run"].location

      merge = tool_named("merge_categories")
      assert_equal [:body, :body], [merge.arguments["source_ids"].location, merge.arguments["dry_run"].location]
    end

    test "merge and delete descriptions tell the model to dry-run first" do
      %w[merge_categories merge_book merge_author delete_admin_category].each do |name|
        description = tool_named(name).description

        assert_match(/dry_run/, description, name)
        assert_match(/first/i, description, name)
      end
    end

    test "merge descriptions say to report warnings and that a dry run has none" do
      %w[merge_book merge_author].each do |name|
        description = tool_named(name).description

        assert_match(/report its `warnings`/, description, name)
        assert_match(/dry run never has warnings/i, description, name)
      end
      assert_match(/did not transfer/, tool_named("merge_book").description)
    end

    test "the tag descriptions do not claim untagging is an unconditional undo" do
      %w[tag_book tag_author].each do |name|
        description = tool_named(name).description

        refute_match(/undoes it/, description, name)
        assert_match(/already had the category/, description, name)
        assert_match(/`source`/, description, name)
      end
      %w[untag_book untag_author].each do |name|
        refute_match(/to undo/, tool_named(name).description, name)
      end
    end

    test "update_admin_category says how null and omission differ" do
      description = tool_named("update_admin_category").description

      assert_match(/omit/i, description)
      assert_match(/null/, description)
    end

    test "no public operation is in the admin catalogue" do
      assert catalog.operations.all? { |operation| operation.path.start_with?("/api/v1/admin/") }
    end

    test "every description is written for a model" do
      catalog.operations.each do |operation|
        assert_operator operation.description.length, :>=, 60, operation.operation_id
        refute_equal operation.title, operation.description, operation.operation_id
        refute_match(/cloudflare/i, operation.description, operation.operation_id)
      end
    end

    test "the public catalogue is unchanged" do
      assert_equal 20, Mcp::Catalog.for(document: :public, domain: :books).operations.size
    end
  end
end
