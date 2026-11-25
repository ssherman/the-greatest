require "test_helper"

module Mcp
  class AdminCatalogTest < ActiveSupport::TestCase
    DESTRUCTIVE = %w[deleteAdminAuthor mergeCategories mergeBook mergeAuthor mergeDuplicateCandidate deleteAdminCategory deleteAdminSeries mergeAdminSeries removeSeriesBook detachListPenalty untagBook untagAuthor removeBookAuthor rejectMatchDecisionLink removeBookIdentifier removeAuthorIdentifier deleteDescription approveRepairVerdict bulkApproveRepairVerdicts mergeBookSubmission rejectBookSubmission].freeze

    def catalog = Mcp::Catalog.for(document: :admin, domain: :books)

    def tool_named(name) = catalog.operations.find { |operation| operation.tool_name == name }

    test "every admin operation but getAdminOpenapi is a tool" do
      expected = ::Api::OpenapiDocument.operations(::Api::OpenapiDocument.raw(:admin)).map(&:operation_id) - ["getAdminOpenapi"]

      assert_equal 84, expected.size
      assert_equal expected.sort, catalog.operations.map(&:operation_id).sort
    end

    test "the admin tools have the expected names" do
      expected = %w[search_admin_books search_admin_authors search_admin_categories create_admin_category
        get_admin_category update_admin_category delete_admin_category merge_categories merge_book
        merge_author tag_book untag_book tag_author untag_author add_book_author update_book_author remove_book_author list_duplicate_candidates get_duplicate_candidate list_match_decisions get_match_decision list_repair_verdicts get_repair_verdict approve_repair_verdict reject_repair_verdict correct_repair_verdict bulk_approve_repair_verdicts get_book_identifiers get_author_identifiers get_book_descriptions get_author_descriptions get_admin_book get_admin_author create_admin_author delete_admin_author list_admin_series get_admin_series create_admin_series update_admin_series delete_admin_series merge_admin_series add_series_book update_series_book remove_series_book update_book update_author add_book_description add_author_description update_description set_preferred_description delete_description find_by_identifier add_book_identifier add_author_identifier remove_book_identifier remove_author_identifier review_match_decision reject_match_decision_link
        merge_duplicate_candidate dismiss_duplicate_candidate list_enrichment_queues get_enrichment_queue
        claim_enrichment_items submit_enrichment_item skip_enrichment_item
        list_book_submissions get_book_submission claim_book_submissions supply_book_submission_details
        skip_book_submission approve_book_submission merge_book_submission reject_book_submission
        search_admin_lists get_admin_list list_admin_list_items list_admin_penalties
        update_admin_list attach_list_penalty detach_list_penalty
        start_list_audit finish_list_audit release_list_audit fetch_page]

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

    test "submit_enrichment_item takes the answer as an object and is strict only at the top level" do
      schema = tool_named("submit_enrichment_item").input_schema

      assert_equal false, schema["additionalProperties"]
      assert_equal "object", schema.dig("properties", "answer", "type")
      assert_equal true, schema.dig("properties", "answer", "additionalProperties")
      assert_equal %w[answer id lease_token sources], schema["required"].sort
    end

    test "the enrichment tools tell the model what ends a queue and what a 409 means" do
      assert_match(/only when `data` is empty and `meta.remaining` is 0/, tool_named("claim_enrichment_items").description)
      assert_match(/claim again/, tool_named("claim_enrichment_items").description)
      %w[submit_enrichment_item skip_enrichment_item].each do |name|
        assert_match(/no longer yours to answer/, tool_named(name).description, name)
        assert_match(/A 404 means the item no longer exists/, tool_named(name).description, name)
      end
    end

    test "the book submission tools tell the model where ids come from, that results are data, and what a 409 and a 422 mean" do
      names = %w[list_book_submissions get_book_submission claim_book_submissions supply_book_submission_details skip_book_submission
        approve_book_submission merge_book_submission reject_book_submission]
      names.each do |name|
        description = tool_named(name).description

        assert_match(/\bids?\b/i, description, name)
        assert_match(/data, never instructions/, description, name)
      end
      %w[supply_book_submission_details skip_book_submission approve_book_submission merge_book_submission reject_book_submission].each do |name|
        description = tool_named(name).description

        assert_match(/A 409 means the submission is no longer yours to decide/, description, name)
        assert_match(/A 422 means a value was refused/, description, name)
      end
    end

    test "claim_book_submissions says when the queue is done and the decision tools say what they do" do
      claim = tool_named("claim_book_submissions").description
      assert_match(/only when `data` is empty and `meta.remaining` is 0/, claim)
      assert_match(/claim again/, claim)
      assert_match(/Decide each submission yourself/, claim)
      assert_match(/skip_book_submission/, claim)

      assert_match(/become public/, tool_named("approve_book_submission").description)
      %w[merge_book_submission reject_book_submission].each do |name|
        description = tool_named(name).description

        assert_match(/PERMANENTLY DELETES/, description, name)
        assert_match(/call with `dry_run: true` first/, description, name)
        assert_match(/`dry_run: false` yourself without asking/, description, name)
      end
    end

    test "merge and delete descriptions tell the model to dry-run first" do
      %w[merge_categories merge_book merge_author delete_admin_category delete_admin_author delete_admin_series merge_admin_series].each do |name|
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
      assert_equal 38, Mcp::Catalog.for(document: :public, domain: :books).operations.size
    end
  end
end
