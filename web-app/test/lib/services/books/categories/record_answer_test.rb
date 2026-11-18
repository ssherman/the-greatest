require "test_helper"

module Services
  module Books
    module Categories
      class RecordAnswerTest < ActiveSupport::TestCase
        BASE_FACT_KEYS = %w[answer apply choice_chat_id context deferred_research dossier label mapping parent_choice_chat_id
          path prompt_version].freeze

        setup do
          @book = ::Books::Book.create!(title: "Untitled Categories Test")
          @dossier = Services::Books::Categorize::Dossier.build(book: @book)
          @n = 0
          @genre = genre("Record Answer Genre")
          Services::Ai::Tasks::Books::CategoryChoiceTask.any_instance.stubs(:call).raises("no chooser call expected")
        end

        def genre(name = nil)
          @n += 1
          ::Books::Category.create!(name: name || "Record Genre #{@n}", category_type: :genre)
        end

        def vocabulary = Services::Books::Categories::Judge.vocabulary

        def answer(overrides = {})
          {recognized: true, confidence: "high", book_type: {value: "unknown", confidence: "low", evidence: "x"},
           genres: [{id: @genre.id, confidence: "high", evidence: "WorldCat"}], audience: {id: nil, confidence: "low", evidence: ""},
           subjects: [], locations: [], unlisted_genres: []}.merge(overrides)
        end

        def record(overrides = {}, args = {})
          book = args.fetch(:book, @book)
          args = args.except(:book)
          Services::Books::Categories::RecordAnswer.call(
            book: book, dossier: Services::Books::Categorize::Dossier.build(book: book), answer: answer(overrides),
            vocabulary: vocabulary, mode: :agent, context: "agent", label: "agent", rejudge: false, provider: "agent", **args
          )
        end

        def linked(book = @book) = book.category_items.direct.includes(:category).map { [it.category.name, it.source] }

        test "a high genre id from the vocabulary is linked with source ai" do
          row = record
          assert_equal ["agent", "applied", "agent"], [row.mode, row.outcome, row.facts["label"]]
          assert_equal [["Record Answer Genre", "ai"]], linked
        end

        test "a genre id not in the vocabulary is unmatched as invalid_id and links nothing" do
          row = record(genres: [{id: 999_999_999, confidence: "high", evidence: "x"}])
          assert_equal ["agent", "nothing_to_apply"], [row.mode, row.outcome]
          assert_equal ["invalid_id"], row.facts["mapping"]["unmatched"].map { it["via"] }
          assert_empty linked
        end

        test "a sixth genre is held back by the cap when the book already holds five" do
          5.times { @book.category_items.create!(category: genre, source: :legacy) }
          row = record
          assert_equal "nothing_to_apply", row.outcome
          assert_equal [[@genre.id, "cap"]], row.facts["apply"]["held_back"].map { [it["id"], it["reason"]] }
          assert_not_includes linked.map(&:first), @genre.name
        end

        test "with rejudge false a legacy link the answer did not pick is kept" do
          other = genre("Legacy Pick")
          @book.category_items.create!(category: other, source: :legacy)
          row = record
          assert_equal "agent", row.mode
          assert_includes linked, ["Legacy Pick", "legacy"]
          assert_includes linked, ["Record Answer Genre", "ai"]
        end

        test "unlisted genres are stored with the answer" do
          row = record(unlisted_genres: [{name: "Bildungsroman", evidence: "x"}])
          assert_equal "Bildungsroman", row.facts["answer"]["unlisted_genres"].first["name"]
        end

        test "confidences are normalised before the answer is used" do
          row = record(confidence: " HIGH ", genres: [{id: @genre.id, confidence: "High", evidence: "x"}])
          assert_equal ["high", "applied"], [row.confidence, row.outcome]
        end

        test "an answer with string keys is accepted" do
          row = Services::Books::Categories::RecordAnswer.call(
            book: @book, dossier: @dossier, answer: answer.deep_stringify_keys, vocabulary: vocabulary,
            mode: :agent, context: "agent", label: "agent", rejudge: false
          )
          assert_equal ["applied", [["Record Answer Genre", "ai"]]], [row.outcome, linked]
        end

        test "not recognized with no evidence is an unrecognized row and links nothing" do
          row = record(recognized: false)
          assert_equal ["unrecognized", "unrecognized"], [row.outcome, row.reason]
          assert_empty linked
        end

        test "a mapper failure is a failed row" do
          Mapper.stubs(:call).returns(Mapper::Result.new(success?: false, errors: ["x"]))
          row = record
          assert_equal ["failed", "x"], [row.outcome, row.error]
          assert_equal "agent", row.mode
        end

        test "a raise after Apply committed is a failed row that keeps the mapping and apply facts" do
          removed = [{id: 7, name: "Gone", type: "subject", source: "legacy"}]
          Apply.stubs(:call).returns(Apply::Result.new(success?: true, errors: [],
            data: {added: [], confirmed: [], removed: removed, held_back: [], type: {applied: false}, rejudged: false}))
          Enrichment.any_instance.stubs(:save!).raises("row boom").then.returns(true)
          row = record
          assert_equal ["failed", "row boom"], [row.outcome, row.error]
          assert_equal [7], row.facts.dig("apply", "removed").map { it["id"] }
          assert_equal [@genre.id], row.facts.dig("mapping", "resolved").map { it["id"] }
        end

        test "a raise before anything is committed propagates" do
          Mapper.stubs(:call).raises("mapper boom")
          error = assert_raises(RuntimeError) { record }
          assert_equal "mapper boom", error.message
          assert_equal 0, @book.enrichments.count
        end

        test "the row's facts have one fixed set of keys, with and without extra facts" do
          with_extra = record({}, {extra_facts: {"queue_request_id" => 7}})
          assert_equal 7, with_extra.facts["queue_request_id"]
          assert_equal (BASE_FACT_KEYS + ["queue_request_id"]).sort, with_extra.facts.keys.sort
          other = ::Books::Book.create!(title: "Another Categories Test")
          plain = record({}, {book: other})
          assert_equal BASE_FACT_KEYS, plain.facts.keys.sort
          assert_equal ["judge", false, Services::Ai::Tasks::Books::BookCategoriesTask::PROMPT_VERSION],
            plain.facts.values_at("path", "deferred_research", "prompt_version")
        end

        test "extra facts are also on a failed row" do
          Mapper.stubs(:call).returns(Mapper::Result.new(success?: false, errors: ["x"]))
          assert_equal 9, record({}, {extra_facts: {"queue_request_id" => 9}}).facts["queue_request_id"]
        end

        test "citations and provider are stored on the row" do
          row = record({}, {citations: ["https://example.org/a"]})
          assert_equal [["https://example.org/a"], "agent"], [row.citations, row.provider]
        end
      end
    end
  end
end
