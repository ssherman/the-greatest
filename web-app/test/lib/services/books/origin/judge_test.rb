# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Origin
      class JudgeTest < ActiveSupport::TestCase
        BookOriginTask = Services::Ai::Tasks::Books::BookOriginTask

        setup do
          @french = ::Books::Country.find_or_create_by!(name: "French")
          @american = ::Books::Country.find_or_create_by!(name: "American")
          @peruvian = ::Books::Country.find_or_create_by!(name: "Peruvian")
          @unknown = ::Books::Country.find_or_create_by!(name: "Unknown")
          @book = new_book("Judge Test Book")
          @chat = AiChat.create!(parent: @book, chat_type: :analysis, model: "gpt-6-sol", provider: :openai)
        end

        def new_book(title, year: 1900, language: :english, countries: [])
          book = ::Books::Book.create!(title: title, first_published_year: year, original_language: languages(language))
          countries.each { |country| book.countries << country }
          book
        end

        def evidence(book, wikidata: nil)
          facts = {"schema_version" => 2}
          facts["wikidata"] = wikidata if wikidata
          book.enrichments.create!(kind: "books.evidence", outcome: :applied, facts: facts)
        end

        def agreeing_wikidata_book
          book = new_book("Wikidata Book", language: :french)
          author = ::Books::Author.create!(name: "Judge French Author")
          author.countries << @french
          book.book_authors.create!(author: author, position: 1)
          evidence(book, wikidata: {"qid" => "Q1", "countries" => ["France"], "country_ids" => [1], "country_matches" => ["French"],
                                    "languages" => [], "publication_years" => []})
          book
        end

        def answer(overrides = {})
          {nationality: "French", confidence: "high", reason: "r", recognized: true, original_language: "French"}.merge(overrides)
        end

        def ok(overrides = {})
          Services::Ai::Result.new(success: true, data: {facts: answer(overrides), citations: []}, ai_chat: @chat)
        end

        def stub_answer(overrides = {})
          BookOriginTask.any_instance.stubs(:call).returns(ok(overrides))
        end

        def stub_answers(first, second)
          BookOriginTask.any_instance.stubs(:call).returns(ok(first)).then.returns(ok(second))
        end

        def judge(book = @book, **args)
          Judge.call(book: book, **args)
        end

        test "the shortcut applies with no AI call" do
          BookOriginTask.any_instance.expects(:call).never
          row = judge(agreeing_wikidata_book, context: "import").data[:enrichments].sole
          assert_equal ["applied", "shortcut", 1, "high"], [row.outcome, row.facts["path"], row.facts["prompt_version"], row.confidence]
        end

        test "a book with a real country makes no AI call" do
          BookOriginTask.any_instance.expects(:call).never
          book = new_book("Has Origin", countries: [@american])
          row = judge(book, context: "backfill").data[:enrichments].sole
          assert_equal ["has_origin", "has_origin", "nothing_to_apply"], [row.reason, row.facts["path"], row.outcome]
        end

        test "force judges a book that has a real country" do
          stub_answer(nationality: "American", confidence: "high")
          book = new_book("Forced", countries: [@american])
          assert_equal "already_set", judge(book, context: "admin", force: true).data[:enrichments].sole.reason
        end

        test "a high knowledge answer applies" do
          stub_answer(nationality: "French", confidence: "high")
          result = judge(context: "import")
          row = result.data[:enrichments].sole
          assert_equal ["applied", "knowledge", "filled", "high", true], [row.outcome, row.mode, row.reason, row.confidence, result.data[:applied]]
          assert_equal "gpt-6-sol", row.model
          assert_equal ["French"], @book.reload.countries.map(&:name)
        end

        test "a low answer researches within the import cap" do
          stub_answers({nationality: "French", confidence: "low"}, {nationality: "French", confidence: "high"})
          rows = judge(context: "import").data[:enrichments]
          assert_equal %w[knowledge research], rows.map(&:mode)
          assert rows.last.applied?
        end

        test "the backfill cap at 0 defers research" do
          stub_answer(nationality: "French", confidence: "low")
          rows = judge(context: "backfill").data[:enrichments]
          assert_equal ["knowledge"], rows.map(&:mode)
          assert rows.sole.facts["deferred_research"]
        end

        test "a backfill researches while under its own cap" do
          Rails.application.config.x.ai.stubs(:categorize_backfill_research_daily_cap).returns(1)
          stub_answers({nationality: "French", confidence: "low"}, {nationality: "French", confidence: "high"})
          assert_equal %w[knowledge research], judge(context: "backfill").data[:enrichments].map(&:mode)
          other = new_book("Another")
          stub_answer(nationality: "French", confidence: "low")
          rows = judge(other, context: "backfill").data[:enrichments]
          assert_equal ["knowledge"], rows.map(&:mode)
          assert rows.sole.facts["deferred_research"]
        end

        test "backfill research rows do not spend the import budget" do
          Rails.application.config.x.ai.stubs(:research_daily_cap).returns(Enrichment.against_research_cap.count + 1)
          @book.enrichments.create!(kind: "books.origin", mode: :research, outcome: :applied, facts: {"context" => "backfill"})
          stub_answers({nationality: "French", confidence: "low"}, {nationality: "French", confidence: "high"})
          assert_equal %w[knowledge research], judge(context: "import").data[:enrichments].map(&:mode)
        end

        test "an error computing needs-research leaves one failed row" do
          stub_answer
          Judge.any_instance.stubs(:real_country?).raises("late")
          rows = judge(context: "import").data[:enrichments]
          assert_equal ["failed"], rows.map(&:outcome)
        end

        test "an exhausted import cap defers research" do
          Rails.application.config.x.ai.stubs(:research_daily_cap).returns(0)
          stub_answer(nationality: "French", confidence: "low")
          assert judge(context: "import").data[:enrichments].sole.facts["deferred_research"]
        end

        test "research_allowed false runs knowledge only and does not defer" do
          stub_answer(nationality: "French", confidence: "low")
          row = judge(context: "import", research_allowed: false).data[:enrichments].sole
          refute row.facts["deferred_research"]
        end

        test "an unrecognized book with no external evidence is unrecognized and researched" do
          stub_answers({recognized: false, nationality: "Unknown", confidence: "low"}, {recognized: true, nationality: "Peruvian", confidence: "high"})
          rows = judge(context: "import").data[:enrichments]
          assert_equal %w[unrecognized applied], rows.map(&:outcome)
          assert_equal "unrecognized", rows.first.reason
          assert_equal ["Peruvian"], @book.reload.countries.map(&:name)
        end

        test "a not-recognized answer is applied when book_facts researched and recognized the book" do
          @book.enrichments.create!(kind: "books.book_facts", outcome: :applied, recognized: true, mode: :research,
            facts: {"origin_countries" => {"value" => ["Peruvian"]}})
          stub_answer(recognized: false, nationality: "Peruvian", confidence: "high")
          row = judge(context: "import", research_allowed: false).data[:enrichments].sole
          assert_equal ["applied", "filled"], [row.outcome, row.reason]
          assert_equal ["Peruvian"], @book.reload.countries.map(&:name)
        end

        test "a medium answer is applied when research-backed book_facts names the country" do
          @book.enrichments.create!(kind: "books.book_facts", outcome: :applied, recognized: true, mode: :research,
            facts: {"origin_countries" => {"value" => ["Peruvian"]}})
          stub_answer(recognized: true, nationality: "Peruvian", confidence: "medium")
          assert_equal "filled", judge(context: "import", research_allowed: false).data[:enrichments].sole.reason
        end

        test "a previously deferred book goes straight to research when research is permitted" do
          @book.enrichments.create!(kind: "books.origin", mode: :knowledge, outcome: :nothing_to_apply,
            facts: {"prompt_version" => 1, "deferred_research" => true, "context" => "backfill"})
          Rails.application.config.x.ai.stubs(:categorize_backfill_research_daily_cap).returns(5)
          stub_answer(nationality: "French", confidence: "high")
          rows = judge(context: "backfill").data[:enrichments]
          assert_equal ["research"], rows.map(&:mode)
          assert rows.sole.applied?
        end

        test "a previously deferred book stays knowledge-only while research is not permitted" do
          @book.enrichments.create!(kind: "books.origin", mode: :knowledge, outcome: :nothing_to_apply,
            facts: {"prompt_version" => 1, "deferred_research" => true, "context" => "backfill"})
          stub_answer(nationality: "French", confidence: "high")
          assert_equal ["knowledge"], judge(context: "backfill").data[:enrichments].map(&:mode)
        end

        def defer_past_cutoff_book
          book = new_book("Brand New Owed", year: 2026)
          stub_answer(nationality: "French", confidence: "high")
          row = judge(book, context: "backfill").data[:enrichments].sole
          assert_equal ["knowledge", "applied", true], [row.mode, row.outcome, row.facts["deferred_research"]]
          assert_equal ["French"], book.reload.countries.map(&:name)
          book
        end

        test "a book whose applied knowledge answer owed research is researched once the cap allows" do
          book = defer_past_cutoff_book
          Rails.application.config.x.ai.stubs(:categorize_backfill_research_daily_cap).returns(5)
          BookOriginTask.any_instance.expects(:call).once.returns(ok(nationality: "French", confidence: "high"))
          assert_difference -> { book.enrichments.where(kind: "books.origin").count }, 1 do
            row = judge(book, context: "backfill").data[:enrichments].sole
            assert_equal ["research", "already_set", false], [row.mode, row.reason, row.facts["deferred_research"]]
          end
        end

        test "a book that owes research and still cannot be researched carries the debt on has_origin" do
          book = defer_past_cutoff_book
          BookOriginTask.any_instance.expects(:call).never
          assert_difference -> { book.enrichments.where(kind: "books.origin").count }, 1 do
            row = judge(book, context: "backfill").data[:enrichments].sole
            assert_equal ["has_origin", true], [row.reason, row.facts["deferred_research"]]
          end
        end

        test "a shortcut on a book that owes research and cannot be researched carries the debt" do
          book = agreeing_wikidata_book
          book.countries << @french
          book.enrichments.create!(kind: "books.origin", mode: :knowledge, outcome: :applied,
            facts: {"prompt_version" => 1, "deferred_research" => true, "context" => "backfill"})
          BookOriginTask.any_instance.expects(:call).never
          row = judge(book, context: "backfill").data[:enrichments].sole
          assert_equal ["shortcut", true], [row.facts["path"], row.facts["deferred_research"]]
        end

        test "a past-cutoff book goes straight to research" do
          book = new_book("Brand New", year: 2026)
          stub_answer(nationality: "French", confidence: "high")
          assert_equal ["research"], judge(book, context: "import").data[:enrichments].map(&:mode)
        end

        test "a past-cutoff book whose research is not permitted runs knowledge and is deferred" do
          book = new_book("Brand New", year: 2026)
          stub_answer(nationality: "French", confidence: "high")
          row = judge(book, context: "backfill").data[:enrichments].sole
          assert_equal "knowledge", row.mode
          assert row.facts["deferred_research"]
        end

        test "force_research researches even over the cap" do
          Rails.application.config.x.ai.stubs(:research_daily_cap).returns(0)
          stub_answer(nationality: "French", confidence: "high")
          assert_equal ["research"], judge(context: "admin", force_research: true).data[:enrichments].map(&:mode)
        end

        test "force_research does not research when research_allowed is false" do
          stub_answer(nationality: "French", confidence: "high")
          rows = judge(context: "admin", force_research: true, research_allowed: false).data[:enrichments]
          assert_equal ["knowledge"], rows.map(&:mode)
        end

        test "a failed task writes a failed row and fails the result" do
          BookOriginTask.any_instance.stubs(:call).returns(Services::Ai::Result.new(success: false, error: "boom"))
          result = judge(context: "import")
          refute result.success?
          row = result.data[:enrichments].sole
          assert row.failed?
          assert_equal "boom", row.error
        end

        test "an answer without a nationality is a failed row" do
          BookOriginTask.any_instance.stubs(:call).returns(Services::Ai::Result.new(success: true, data: {facts: {}, citations: []}, ai_chat: @chat))
          assert judge(context: "import").data[:enrichments].sole.failed?
        end

        test "an exception after the task call writes a failed row" do
          stub_answer
          Apply.stubs(:call).raises("kaboom")
          result = judge(context: "import")
          refute result.success?
          assert_equal "kaboom", result.data[:enrichments].sole.error
        end

        test "a blank title is skipped" do
          @book.update_columns(title: "")
          row = judge(context: "import").data[:enrichments].sole
          assert_equal ["skipped", "missing_inputs"], [row.outcome, row.reason]
        end

        test "rows carry the context, label and prompt version" do
          stub_answer
          facts = judge(context: "backfill", label: "run-1").data[:enrichments].sole.facts
          assert_equal ["backfill", "run-1", "judge", 1], facts.values_at("context", "label", "path", "prompt_version")
          assert_equal "filled", facts.dig("origin", "reason")
        end
      end
    end
  end
end
