# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Categories
      class JudgeTest < ActiveSupport::TestCase
        BookCategoriesTask = Services::Ai::Tasks::Books::BookCategoriesTask

        setup do
          @book = books_books(:war_and_peace)
          @novels = categories(:books_novels_genre)
          @chat = AiChat.create!(parent: @book, chat_type: :analysis, model: "gpt-6-sol", provider: :openai)
          @choice_chat = AiChat.create!(parent: @book, chat_type: :analysis, model: "gpt-6-sol", provider: :openai)
          @external = false
          @research_backed = false
          Rails.application.config.x.ai.stubs(:categories_judge_enabled).returns(true)
          stub_dossier
        end

        def stub_dossier
          dossier = stub("dossier", external?: @external, research_backed?: @research_backed, to_ledger: {"sections" => ["record"]})
          Categorize::Dossier.stubs(:build).returns(dossier)
        end

        def answer(overrides = {})
          {recognized: true, confidence: "high", book_type: {value: "fiction", confidence: "high", evidence: "x"},
           genres: [{id: @novels.id, confidence: "high", evidence: "WorldCat"}], audience: {id: nil}, subjects: [],
           locations: [], unlisted_genres: ["Bildungsroman"]}.merge(overrides)
        end

        def ok(overrides = {})
          Services::Ai::Result.new(success: true, data: {facts: answer(overrides), citations: [{"url" => "https://x.test"}]}, ai_chat: @chat)
        end

        def stub_task(*answers)
          returns = answers.map { |a| a.is_a?(Services::Ai::Result) ? a : ok(a) }
          stub = BookCategoriesTask.any_instance.stubs(:call).returns(returns.first)
          returns.drop(1).each { |r| stub = stub.then.returns(r) }
        end

        def mapped
          resolved = [{type: "genre", category: @novels, proposed: @novels.id.to_s, confidence: "high", evidence: "WorldCat", via: "id"}]
          Mapper::Result.new(success?: true, errors: [],
            data: {resolved: resolved, unmatched: [{type: "subject", proposed: "Odd", via: "no_candidate"}], ai_chat: @choice_chat})
        end

        def applied_data(added: [{id: @novels.id, name: "Novels", type: "genre"}])
          {added: added, confirmed: [], removed: [], held_back: [], type: {applied: false}, rejudged: false}
        end

        def stub_pipeline(apply_data = applied_data)
          Mapper.stubs(:call).returns(mapped)
          Apply.stubs(:call).returns(Apply::Result.new(success?: true, errors: [], data: apply_data))
        end

        def judge(**args)
          Judge.call(book: @book, context: "import", **args)
        end

        test "happy path writes one applied row with its facts" do
          stub_task({})
          stub_pipeline
          result = judge
          row = result.data[:enrichments].sole
          assert result.success?
          assert result.data[:applied]
          assert_equal ["books.categories", "applied", "knowledge", "applied", "high", true, "gpt-6-sol"],
            [row.kind, row.outcome, row.mode, row.reason, row.confidence, row.recognized, row.model]
          assert_equal [Services::Ai::Tasks::Books::BookCategoriesTask::PROMPT_VERSION, "import"], [row.facts["prompt_version"], row.facts["context"]]
          assert_equal({"sections" => ["record"]}, row.facts["dossier"])
          assert_equal ["Bildungsroman"], row.facts["answer"]["unlisted_genres"]
          assert_equal [@novels.id, "Novels", "genre", "id", "high"],
            row.facts["mapping"]["resolved"].first.values_at("id", "name", "type", "via", "confidence")
          assert_equal "no_candidate", row.facts["mapping"]["unmatched"].first["via"]
          assert_equal [@novels.id], row.facts["apply"]["added"].map { |a| a["id"] }
          assert_equal @choice_chat.id, row.facts["choice_chat_id"]
          assert_equal @chat, row.ai_chat
          assert_equal [{"url" => "https://x.test"}], row.citations
          assert_equal false, row.facts["deferred_research"]
        end

        test "nothing added, confirmed or removed is nothing_to_apply" do
          stub_task({})
          stub_pipeline(applied_data(added: []))
          row = judge.data[:enrichments].sole
          assert_equal ["nothing_to_apply", "nothing_applied"], [row.outcome, row.reason]
        end

        test "an applied book type alone is applied" do
          stub_task({})
          stub_pipeline(applied_data(added: []).merge(type: {applied: true}))
          assert judge.data[:enrichments].sole.applied?
        end

        test "disabled writes one skipped row, calls no task and applies nothing" do
          Rails.application.config.x.ai.stubs(:categories_judge_enabled).returns(false)
          BookCategoriesTask.any_instance.expects(:call).never
          Mapper.expects(:call).never
          Apply.expects(:call).never
          result = judge
          row = result.data[:enrichments].sole
          assert result.success?
          assert_equal ["skipped", "disabled"], [row.outcome, row.reason]
          assert_not result.data[:applied]
        end

        test "a disabled-skipped book is still a backfill candidate" do
          Rails.application.config.x.ai.stubs(:categories_judge_enabled).returns(false)
          judge
          assert_equal Services::Ai::Tasks::Books::BookCategoriesTask::PROMPT_VERSION.to_s, @book.enrichments.where(kind: "books.categories").sole.facts["prompt_version"].to_s
          assert_includes Categorize::Backfill.candidates(scope: "categories_only", book_ids: [@book.id]).pluck(:id), @book.id
        end

        test "confidence strings are normalised before mapping and applying" do
          stub_task({confidence: " High ", book_type: {value: "fiction", confidence: "High"}, genres: [{id: @novels.id, confidence: "HIGH", evidence: "x"}]})
          Mapper.expects(:call).with { |args| args[:answer][:confidence] == "high" && args[:answer].dig(:genres, 0, :confidence) == "high" }.returns(mapped)
          Apply.expects(:call).with { |args| args[:answer].dig(:book_type, :confidence) == "high" }
            .returns(Apply::Result.new(success?: true, errors: [], data: applied_data))
          assert judge.success?
        end

        test "mapping facts carry the unmatched candidate ids and Apply receives the unmatched list" do
          stub_task({})
          unmatched = [{type: "subject", proposed: "Odd", via: "declined", candidate_ids: [5, 6]}]
          Mapper.stubs(:call).returns(Mapper::Result.new(success?: true, errors: [], data: {resolved: [], unmatched: unmatched, ai_chat: nil}))
          Apply.expects(:call).with(has_entry(unmatched: unmatched)).returns(Apply::Result.new(success?: true, errors: [], data: applied_data(added: [])))
          row = judge.data[:enrichments].sole
          assert_equal [5, 6], row.facts.dig("mapping", "unmatched", 0, "candidate_ids")
        end

        test "an exception after Apply committed keeps the apply and mapping facts on the failed row" do
          stub_task({})
          stub_pipeline(applied_data.merge(removed: [{id: 7, name: "Gone", type: "subject", source: "legacy"}]))
          # The first row write (the applied row) fails; the rescue's failed row goes through.
          Enrichment.any_instance.stubs(:save!).raises("row boom").then.returns(true)
          result = judge
          row = result.data[:enrichments].sole
          assert_not result.success?
          assert_equal ["failed", "row boom"], [row.outcome, row.error]
          assert_equal [7], row.facts.dig("apply", "removed").map { |r| r["id"] }
          assert_equal [@novels.id], row.facts.dig("mapping", "resolved").map { |r| r["id"] }
        end

        test "a blank title is skipped" do
          @book.stubs(:title).returns("")
          BookCategoriesTask.any_instance.expects(:call).never
          row = judge.data[:enrichments].sole
          assert_equal ["skipped", "missing_inputs"], [row.outcome, row.reason]
        end

        test "unrecognized without external evidence applies nothing and defers when research is not permitted" do
          Rails.application.config.x.ai.stubs(:research_daily_cap).returns(0)
          stub_task({recognized: false, confidence: "low"})
          Mapper.expects(:call).never
          Apply.expects(:call).never
          row = judge.data[:enrichments].sole
          assert_equal ["unrecognized", "unrecognized"], [row.outcome, row.reason]
          assert row.facts["deferred_research"]
        end

        test "unrecognized with research permitted researches next" do
          Rails.application.config.x.ai.stubs(:research_daily_cap).returns(Enrichment.against_research_cap.count + 5)
          stub_task({recognized: false, confidence: "low"}, {})
          stub_pipeline
          rows = judge.data[:enrichments]
          assert_equal %w[knowledge research], rows.map(&:mode)
          assert_equal %w[unrecognized applied], rows.map(&:outcome)
          assert_equal false, rows.first.facts["deferred_research"]
        end

        test "an unrecognized answer is applied when the dossier is external" do
          @external = true
          stub_dossier
          stub_task({recognized: false})
          stub_pipeline
          assert judge.data[:enrichments].sole.applied?
        end

        test "research_allowed false never researches and does not defer" do
          Rails.application.config.x.ai.stubs(:research_daily_cap).returns(Enrichment.against_research_cap.count + 5)
          stub_task({recognized: false})
          row = judge(research_allowed: false).data[:enrichments].sole
          assert_equal ["knowledge", false], [row.mode, row.facts["deferred_research"]]
        end

        test "force_research makes the first row research" do
          stub_task({})
          stub_pipeline
          assert_equal ["research"], judge(force_research: true).data[:enrichments].map(&:mode)
        end

        test "a past-cutoff book is researched when permitted, deferred when not" do
          @book.stubs(:first_published_year).returns(Rails.application.config.x.ai.knowledge_cutoff_year)
          stub_pipeline
          stub_task({})
          Rails.application.config.x.ai.stubs(:research_daily_cap).returns(0)
          row = judge.data[:enrichments].sole
          assert_equal ["knowledge", true], [row.mode, row.facts["deferred_research"]]
          Rails.application.config.x.ai.stubs(:research_daily_cap).returns(Enrichment.against_research_cap.count + 5)
          assert_equal ["research"], judge.data[:enrichments].map(&:mode)
        end

        test "a book that owes research is researched once it is permitted" do
          Rails.application.config.x.ai.stubs(:research_daily_cap).returns(0)
          stub_task({recognized: false})
          assert judge.data[:enrichments].sole.facts["deferred_research"]
          Rails.application.config.x.ai.stubs(:research_daily_cap).returns(Enrichment.against_research_cap.count + 5)
          stub_task({})
          stub_pipeline
          assert_equal ["research"], judge.data[:enrichments].map(&:mode)
        end

        test "a failed task writes a failed row and success is false" do
          BookCategoriesTask.any_instance.stubs(:call).returns(Services::Ai::Result.new(success: false, error: "boom", ai_chat: @chat))
          Apply.expects(:call).never
          result = judge
          row = result.data[:enrichments].sole
          assert_not result.success?
          assert_equal ["failed", "boom"], [row.outcome, row.error]
        end

        test "an exception writes a failed row" do
          BookCategoriesTask.any_instance.stubs(:call).raises("kaboom")
          row = judge.data[:enrichments].sole
          assert_equal ["failed", "kaboom"], [row.outcome, row.error]
        end

        test "a failed mapping writes a failed row and never applies" do
          stub_task({})
          Mapper.stubs(:call).returns(Mapper::Result.new(success?: false, data: nil, errors: ["chooser down", "again"]))
          Apply.expects(:call).never
          result = judge
          row = result.data[:enrichments].sole
          assert_not result.success?
          assert_equal ["failed", "chooser down; again"], [row.outcome, row.error]
        end

        test "rejudge is false for import and true for backfill and admin" do
          {"import" => false, "backfill" => true, "admin" => true}.each do |context, expected|
            stub_task({})
            Mapper.stubs(:call).returns(mapped)
            Apply.expects(:call).with(has_entry(rejudge: expected)).returns(Apply::Result.new(success?: true, errors: [], data: applied_data))
            Judge.call(book: @book, context: context)
          end
        end

        test "no chooser call leaves choice_chat_id nil" do
          stub_task({})
          Mapper.stubs(:call).returns(Mapper::Result.new(success?: true, errors: [], data: {resolved: [], unmatched: [], ai_chat: nil}))
          Apply.stubs(:call).returns(Apply::Result.new(success?: true, errors: [], data: applied_data(added: [])))
          assert_nil judge.data[:enrichments].sole.facts["choice_chat_id"]
        end
      end
    end
  end
end
