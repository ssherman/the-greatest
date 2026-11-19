require "test_helper"

module Services
  module Books
    module Origin
      class RecordAnswerTest < ActiveSupport::TestCase
        setup do
          @book = ::Books::Book.create!(title: "Untitled Origin Test")
          @dossier = Services::Books::Categorize::Dossier.build(book: @book)
        end

        def record(answer, mode: :agent)
          Services::Books::Origin::RecordAnswer.call(book: @book, dossier: @dossier, answer: answer, mode: mode,
            context: "agent", label: "agent", citations: ["https://example.org/a"], provider: "agent")
        end

        test "a high answer is written and recorded" do
          row = record({recognized: true, original_language: "Japanese", nationality: "Japanese", confidence: "high", reason: "r"})
          assert_equal ["agent", "applied", "filled", "high"], [row.mode, row.outcome, row.reason, row.confidence]
          assert_equal ["Japanese"], @book.countries.reload.pluck(:name)
          assert_equal ["agent", "agent", "judge", false], row.facts.values_at("context", "label", "path", "deferred_research")
          assert_equal Services::Ai::Tasks::Books::BookOriginTask::PROMPT_VERSION, row.facts["prompt_version"]
          assert_equal ["https://example.org/a"], row.citations
        end

        test "extra facts are merged into the row's facts" do
          row = Services::Books::Origin::RecordAnswer.call(book: @book, dossier: @dossier, mode: :agent,
            answer: {recognized: true, original_language: nil, nationality: "Japanese", confidence: "high", reason: "r"},
            context: "agent", label: "agent", extra_facts: {"queue_request_id" => 7})
          assert_equal 7, row.facts["queue_request_id"]
        end

        test "the row's facts have one fixed set of keys, with and without extra facts" do
          base = %w[answer context deferred_research dossier label origin path prompt_version]
          answer = {recognized: true, original_language: nil, nationality: "Japanese", confidence: "high", reason: "r"}
          with_extra = Services::Books::Origin::RecordAnswer.call(book: @book, dossier: @dossier, answer: answer, mode: :agent,
            context: "agent", label: "agent", extra_facts: {"queue_request_id" => 7})
          assert_equal (base + ["queue_request_id"]).sort, with_extra.facts.keys.sort
          other = ::Books::Book.create!(title: "Another Origin Test")
          plain = Services::Books::Origin::RecordAnswer.call(book: other, dossier: Services::Books::Categorize::Dossier.build(book: other),
            answer: answer, mode: :agent, context: "agent", label: "agent")
          assert_equal base, plain.facts.keys.sort
        end

        test "a medium answer with no stored evidence is held" do
          row = record({recognized: true, original_language: nil, nationality: "Japanese", confidence: "medium", reason: "r"})
          assert_equal ["nothing_to_apply", "unsupported"], [row.outcome, row.reason]
          assert_empty @book.countries.reload
        end

        test "a medium answer with no stored evidence is written when the caller accepts medium" do
          row = Services::Books::Origin::RecordAnswer.call(book: @book, dossier: @dossier, mode: :agent,
            answer: {recognized: true, original_language: nil, nationality: "Japanese", confidence: "medium", reason: "r"},
            context: "agent", label: "agent", accept_medium: true)
          assert_equal ["applied", "filled", "medium"], [row.outcome, row.reason, row.confidence]
          assert_equal ["Japanese"], @book.countries.reload.pluck(:name)
        end

        test "a nationality that matches no country applies nothing and does not raise" do
          row = record({recognized: true, original_language: nil, nationality: "Atlantean", confidence: "high", reason: "r"})
          assert_equal ["nothing_to_apply", "no_match"], [row.outcome, row.reason]
        end

        test "a held country is never overwritten" do
          @book.book_countries.create!(country: ::Books::Country.find_by!(name: "French"))
          dossier = Services::Books::Categorize::Dossier.build(book: @book)
          row = Services::Books::Origin::RecordAnswer.call(book: @book, dossier: dossier,
            answer: {recognized: true, original_language: nil, nationality: "Japanese", confidence: "high", reason: "r"},
            mode: :agent, context: "agent", label: "agent")
          assert_equal "already_set", row.reason
          assert_equal ["French"], @book.countries.reload.pluck(:name)
        end

        test "not recognized with no evidence is an unrecognized row" do
          row = record({recognized: false, original_language: nil, nationality: "Unknown", confidence: "low", reason: "r"})
          assert_equal "unrecognized", row.outcome
        end
      end
    end
  end
end
