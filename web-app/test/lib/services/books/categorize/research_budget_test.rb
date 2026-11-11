# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Categorize
      class ResearchBudgetTest < ActiveSupport::TestCase
        setup do
          @book = books_books(:war_and_peace)
        end

        def research_row(kind, context)
          @book.enrichments.create!(kind: kind, mode: :research, outcome: :applied, facts: {"context" => context})
        end

        test "the backfill counts research rows of both kinds against its own cap" do
          Rails.application.config.x.ai.stubs(:categorize_backfill_research_daily_cap).returns(2)
          assert ResearchBudget.permitted?(context: "backfill")
          research_row("books.origin", "backfill")
          assert ResearchBudget.permitted?(context: "backfill")
          research_row("books.categories", "backfill")
          assert_not ResearchBudget.permitted?(context: "backfill")
        end

        test "the backfill cap at 0 permits nothing" do
          assert_not ResearchBudget.permitted?(context: "backfill")
        end

        test "import rows count against the import cap and backfill rows do not" do
          Rails.application.config.x.ai.stubs(:research_daily_cap).returns(Enrichment.against_research_cap.count + 1)
          research_row("books.categories", "backfill")
          research_row("books.origin", "backfill")
          assert ResearchBudget.permitted?(context: "import")
          research_row("books.categories", "import")
          assert_not ResearchBudget.permitted?(context: "import")
        end

        test "knowledge rows do not count" do
          Rails.application.config.x.ai.stubs(:categorize_backfill_research_daily_cap).returns(1)
          @book.enrichments.create!(kind: "books.categories", mode: :knowledge, outcome: :applied, facts: {"context" => "backfill"})
          assert ResearchBudget.permitted?(context: "backfill")
        end
      end
    end
  end
end
