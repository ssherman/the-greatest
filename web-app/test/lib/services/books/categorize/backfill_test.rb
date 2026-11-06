# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Categorize
      class BackfillTest < ActiveSupport::TestCase
        include Workflows::DispatchHelper

        setup do
          stub_workflow_dispatch
          # Created in the reverse of the expected order, so id order alone cannot pass.
          @american = book("American")
          @american.countries << country("United States")
          @unknown_only = book("Unknown only")
          @unknown_only.countries << country("Unknown")
          @no_country = book("No country")
          @rank_two = book("Rank two")
          @rank_one = book("Rank one")
          @other_config_only = book("Other config only")
          primary = ::Books::RankingConfiguration.default_primary
          ::RankedItem.create!(item: @rank_two, ranking_configuration: primary, rank: 2, score: 1)
          ::RankedItem.create!(item: @rank_one, ranking_configuration: primary, rank: 1, score: 2)
          other = ::Books::RankingConfiguration.where(primary: false).first
          ::RankedItem.create!(item: @other_config_only, ranking_configuration: other, rank: 1, score: 1)
          @ranked = @rank_one
        end

        def book(title)
          ::Books::Book.create!(title: title)
        end

        def country(name)
          ::Books::Country.find_or_create_by!(name: name) { it.slug = name.parameterize }
        end

        def origin_row(book, outcome: :applied, **facts)
          book.enrichments.create!(kind: "books.origin", outcome: outcome,
            facts: {"prompt_version" => 1, "context" => "backfill"}.merge(facts.stringify_keys))
        end

        test "orders ranked books by rank, then books without a real origin, then the rest, ties by id" do
          ids = [@american, @unknown_only, @no_country, @rank_two, @rank_one, @other_config_only].map(&:id)
          # other_config_only has no country, so it sits in the placeholder bucket by id order.
          expected = [@rank_one, @rank_two, @unknown_only, @no_country, @other_config_only, @american]
          assert_equal expected.map(&:id), Backfill.candidates.where(id: ids).pluck(:id)
        end

        test "leaves out books done under the current prompt version" do
          origin_row(@american)
          refute_includes Backfill.candidates.pluck(:id), @american.id
        end

        test "a deferred book is left out at cap 0 and included once the cap is above 0" do
          deferred = book("Deferred")
          origin_row(deferred, deferred_research: true)
          refute_includes Backfill.candidates.pluck(:id), deferred.id

          Rails.application.config.x.ai.stubs(:categorize_backfill_research_daily_cap).returns(5)
          assert_includes Backfill.candidates.pluck(:id), deferred.id
        end

        test "a rerun does not lay its slots over a running plan" do
          Backfill.call(scope: "origin_only", limit: 2, label: "t", book_ids: [@american.id, @unknown_only.id])
          last = WorkflowRun.where(workflow: "books.book_categorize").map { it.step(:evidence).run_after }.max

          Backfill.call(scope: "origin_only", limit: 1, label: "t", book_ids: [@no_country.id])
          newest = WorkflowRun.where(workflow: "books.book_categorize", enrichable: @no_country).sole.step(:evidence).run_after
          assert_operator newest, :>=, last + Backfill::SPACING.seconds
        end

        test "keeps books whose latest row failed, was skipped or ran an older prompt" do
          Rails.application.config.x.ai.stubs(:categorize_backfill_research_daily_cap).returns(5)
          deferred = book("Deferred")
          failed = book("Failed")
          skipped = book("Skipped")
          older = book("Older")
          origin_row(deferred, deferred_research: true)
          origin_row(failed, outcome: :failed)
          origin_row(skipped, outcome: :skipped)
          origin_row(older, prompt_version: 0)

          assert_empty [deferred, failed, skipped, older].map(&:id) - Backfill.candidates.pluck(:id)
        end

        test "only the latest row counts" do
          origin_row(@american, outcome: :failed)
          origin_row(@american)
          refute_includes Backfill.candidates.pluck(:id), @american.id

          origin_row(@american, outcome: :failed)
          assert_includes Backfill.candidates.pluck(:id), @american.id
        end

        test "leaves out books with a running book_enrichment run" do
          WorkflowRun.create!(workflow: "books.book_enrichment", enrichable: @american, status: :running, definition_version: 1, initiated_by: "test")
          refute_includes Backfill.candidates.pluck(:id), @american.id
          assert_includes Backfill.candidates.pluck(:id), @ranked.id
        end

        test "book_ids restricts the candidates" do
          assert_equal [@american.id], Backfill.candidates(book_ids: [@american.id]).pluck(:id)
        end

        test "plans paced runs and reuses running ones" do
          result = Backfill.call(scope: "origin_only", limit: 2, label: "t", book_ids: [@american.id, @unknown_only.id])
          assert result.success?
          assert_equal 2, result.data[:planned]
          assert_equal 0, result.data[:reused]
          assert_in_delta Time.current + (2 * Backfill::SPACING), result.data[:done_at], 5

          runs = WorkflowRun.where(workflow: "books.book_categorize").order(:id)
          assert_equal [{"context" => "backfill", "label" => "t"}], runs.map { it.options.slice("context", "label") }.uniq
          assert_operator runs.last.step(:evidence).run_after, :>, runs.first.step(:evidence).run_after

          again = Backfill.call(scope: "origin_only", limit: 2, label: "t", book_ids: [@american.id, @unknown_only.id])
          assert_equal 2, again.data[:reused]
          assert_equal 2, WorkflowRun.where(workflow: "books.book_categorize").count
        end

        test "a re-plan puts a new book one spacing after the last existing slot" do
          ids = [@american.id, @unknown_only.id, @no_country.id]
          Backfill.call(scope: "origin_only", limit: nil, label: "t", book_ids: ids)
          last_slot = WorkflowRun.where(workflow: "books.book_categorize").map { it.step(:evidence).run_after }.max

          again = Backfill.call(scope: "origin_only", limit: nil, label: "t", book_ids: ids + [@rank_one.id])
          assert_equal [4, 3], [again.data[:planned], again.data[:reused]]
          new_slot = WorkflowRun.where(workflow: "books.book_categorize", enrichable: @rank_one).sole.step(:evidence).run_after
          assert_in_delta last_slot + Backfill::SPACING, new_slot, 1
          assert_in_delta new_slot + Backfill::SPACING, again.data[:done_at], 1
        end

        test "the limit caps what is planned" do
          result = Backfill.call(scope: "origin_only", limit: 1, label: "t", book_ids: [@american.id, @unknown_only.id])
          assert_equal 1, result.data[:planned]
        end

        test "skips a book that disappears between the id pluck and the load" do
          relation = stub(limit: nil)
          relation.stubs(:pluck).with(:id).returns([0, @american.id])
          Backfill.stubs(:candidates).returns(relation)

          result = Backfill.call(scope: "origin_only", limit: nil, label: "t")
          assert result.success?
          assert_equal 1, result.data[:planned]
        end

        test "refuses any other scope" do
          result = Backfill.call(scope: "all", limit: 1, label: "t")
          refute result.success?
          assert_equal ["scope all arrives with stage 3 (categories); use origin_only"], result.errors
        end
      end
    end
  end
end
