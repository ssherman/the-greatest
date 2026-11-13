# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsReimport
      class MatchEditionTest < ActiveSupport::TestCase
        Cand = Struct.new(:record)
        Fake = Struct.new(:response) do
          def call(**) = response
        end

        # Answers each call in turn and keeps the queries it was asked.
        class SeqFinder
          attr_reader :queries

          def initialize(*responses)
            @responses = responses
            @queries = []
          end

          def call(query:, **)
            @queries << query
            @responses.shift
          end
        end

        setup do
          @edition = ::Books::GoodreadsEdition.create!(goodreads_book_id: 90_001, signature: "me-sig", title: "War and Peace", primary_author: "Leo Tolstoy")
          @pick = books_books(:war_and_peace)
          @other = books_books(:crime_and_punishment)
          @key = "reimport:edition:#{@edition.id}"
          # Every "none" asks for an English title; by default there is none, so the earlier behaviour is unchanged.
          Services::Ai::Tasks::Books::EnglishTitleTask.any_instance.stubs(:call)
            .returns(Services::Ai::Result.new(success: true, data: {title: nil, confidence: "high", reason: "already English"}))
        end

        def english_returning(title, confidence = "high", success: true)
          result = if success
            Services::Ai::Result.new(success: true, data: {title: title, confidence: confidence, reason: "translated"})
          else
            Services::Ai::Result.new(success: false, error: "boom")
          end
          klass = stub
          klass.stubs(:new).returns(stub(call: result))
          klass
        end

        # The same-work task answering each call in turn; the books each call was offered land in offered.
        def tasks_returning(*book_ids, offered: [])
          klass = stub
          tasks = book_ids.map { |id| stub(call: Services::Ai::Result.new(success: true, data: {book_id: id, confidence: "high", reason: "r"})) }
          klass.stubs(:new).with { |args| offered << args }.returns(*tasks)
          klass
        end

        def run_english(finder, task_class, english_class)
          MatchEdition.call(edition: @edition, finder: finder, task_class: task_class, english_task_class: english_class)
        end

        def match(record: nil, candidates: [], decided_by: :rule, sources_failed: [])
          DataImporters::Match.new(outcome: record ? :matched : :unmatched, record: record, confidence: :high, decided_by: decided_by,
            candidates: candidates.map { |r| Cand.new(r) }, sources_failed: sources_failed)
        end

        def task_returning(book_id, confidence = "high", success: true)
          result = if success
            Services::Ai::Result.new(success: true, data: {book_id: book_id, confidence: confidence, reason: "because"})
          else
            Services::Ai::Result.new(success: false, error: "boom")
          end
          task = stub(call: result)
          klass = stub
          klass.stubs(:new).returns(task)
          klass
        end

        def run_match(finder_match, task_class)
          MatchEdition.call(edition: @edition, finder: Fake.new(finder_match), task_class: task_class)
        end

        def verdict = ::Books::RepairVerdict.find_by!(kind: :reimport_match, subject_key: @key)

        test "AI confirms the finder's match at high: matched and auto-approved" do
          result = run_match(match(record: @pick, candidates: [@other]), task_returning(@pick.id))

          assert_equal :matched, result.data[:outcome]
          assert verdict.approved?
          assert_equal "matched", verdict.payload["outcome"]
          assert_equal @pick.id, verdict.payload["book_id"]
          assert_equal [@pick.id, @other.id], verdict.payload["candidate_book_ids"]
          assert_equal({"answer" => @pick.id, "confidence" => "high", "reason" => "because"}, verdict.payload["ai"])
          assert_equal @edition.id, verdict.payload["goodreads_edition_id"]
          assert_equal 90_001, verdict.payload["goodreads_book_id"]
          assert verdict.payload["facts"].key?("full_title")
          assert verdict.confidence_high?
        end

        test "AI confirms the finder's match at medium: matched but proposed" do
          run_match(match(record: @pick), task_returning(@pick.id, "medium"))

          assert verdict.proposed?
          assert_equal @pick.id, verdict.payload["book_id"]
          assert verdict.confidence_medium?
        end

        test "AI confirms the finder's match at low: matched but proposed" do
          run_match(match(record: @pick), task_returning(@pick.id, "low"))

          assert verdict.proposed?
        end

        test "AI picks another candidate at high: matched but proposed" do
          run_match(match(record: @pick, candidates: [@other]), task_returning(@other.id))

          assert verdict.proposed?
          assert_equal @other.id, verdict.payload["book_id"]
        end

        test "AI picks a candidate when the finder found no match: proposed" do
          run_match(match(candidates: [@other]), task_returning(@other.id))

          assert verdict.proposed?
          assert_equal "matched", verdict.payload["outcome"]
        end

        # An import-made book on no list: a post-import id (Cohort) with no list item. Fixture books are trusted by id.
        def derived_book(id = 20_001) = ::Books::Book.create!(id: id, title: "Derived #{id}")

        test "AI says none at high and every candidate is import-made: create, auto-approved" do
          result = run_match(match(candidates: [derived_book]), task_returning(nil, "high"))

          assert_equal :create, result.data[:outcome]
          assert verdict.approved?
          assert_equal "create", verdict.payload["outcome"]
          assert_nil verdict.payload["book_id"]
        end

        test "AI says none at high next to a trusted candidate: create, proposed" do
          # Flowers for Algernon: the AI read the catalog year as the short story's and answered none beside the novel.
          result = run_match(match(candidates: [derived_book, @other]), task_returning(nil, "high"))

          assert_equal :create, result.data[:outcome]
          assert verdict.proposed?
          assert_equal "create", verdict.payload["outcome"]
        end

        test "AI says none at high next to a listed import-made candidate: create, proposed" do
          listed = derived_book
          ListItem.create!(list: lists(:books_list), listable: listed, position: 99)
          run_match(match(candidates: [listed]), task_returning(nil, "high"))

          assert verdict.proposed?
        end

        test "AI says none at medium or low with candidates: create, proposed" do
          %w[medium low].each do |confidence|
            ::Books::RepairVerdict.where(subject_key: @key).delete_all
            run_match(match(candidates: [@other]), task_returning(nil, confidence))

            assert verdict.proposed?, confidence
            assert_equal "create", verdict.payload["outcome"]
          end
        end

        test "AI says none but the finder matched: create, proposed" do
          run_match(match(record: @pick), task_returning(nil, "high"))

          assert verdict.proposed?
          assert_equal "create", verdict.payload["outcome"]
        end

        test "no candidates at all: create without asking the AI" do
          klass = mock
          klass.expects(:new).never

          result = run_match(match, klass)

          assert_equal :create, result.data[:outcome]
          assert verdict.approved?
          assert verdict.confidence_certain?
          assert verdict.decided_by_rule?
          assert_empty verdict.payload["candidate_book_ids"]
        end

        test "candidates without a record are skipped and the list stops at six" do
          extra = Array.new(7) { |i| ::Books::Book.create!(title: "Extra #{i}") }
          captured = nil
          task = stub(call: Services::Ai::Result.new(success: true, data: {book_id: nil, confidence: "low", reason: "r"}))
          klass = stub
          klass.stubs(:new).with { |args| captured = args[:books] }.returns(task)
          finder_match = DataImporters::Match.new(outcome: :unmatched, candidates: [Cand.new(nil)] + extra.map { |r| Cand.new(r) }, decided_by: :rule)

          run_match(finder_match, klass)

          assert_equal extra.first(6).map(&:id), captured.map(&:id)
        end

        test "an AI error records nothing and returns :retry" do
          result = run_match(match(record: @pick), task_returning(nil, success: false))

          assert_equal :retry, result.data[:outcome]
          assert_not ::Books::RepairVerdict.exists?(subject_key: @key)
        end

        test "a failed finder source or a fallback records nothing and returns :retry" do
          klass = mock
          klass.expects(:new).never

          assert_equal :retry, run_match(match(sources_failed: [:worldcat]), klass).data[:outcome]
          assert_equal :retry, run_match(match(decided_by: :fallback), klass).data[:outcome]
          assert_not ::Books::RepairVerdict.exists?(subject_key: @key)
        end

        test "an existing non-rejected verdict is kept without calling the finder" do
          existing = ::Books::RepairVerdict.create!(kind: :reimport_match, subject_key: @key, payload: {}, decided_by: :ai, status: :proposed, confidence: :low)
          finder = mock
          finder.expects(:call).never

          result = MatchEdition.call(edition: @edition, finder: finder)

          assert_equal :kept, result.data[:outcome]
          assert_equal existing, result.data[:verdict]
        end

        test "a current rejected verdict is left alone: no finder, no AI" do
          rejected = ::Books::RepairVerdict.create!(kind: :reimport_match, subject_key: @key, payload: {"x" => 1}, decided_by: :ai, status: :rejected, confidence: :low)
          finder = mock
          finder.expects(:call).never
          klass = mock
          klass.expects(:new).never

          result = MatchEdition.call(edition: @edition, finder: finder, task_class: klass)

          assert_equal :rejected, result.data[:outcome]
          assert_equal rejected, result.data[:verdict]
          assert_equal({"x" => 1}, rejected.reload.payload)
        end

        test "call without a finder builds the blinded one, excluding nothing" do
          DataImporters::Books::Book::Finder.expects(:new).with { |**kw|
            !kw.key?(:exclude_ids) && kw[:identifier_sources] == DataImporters::Books::Book::Finder::TRUSTED_IDENTIFIER_SOURCES
          }.returns(Fake.new(match))

          assert_equal :create, MatchEdition.call(edition: @edition).data[:outcome]
        end

        test "the finder's record also listed among its candidates counts once" do
          run_match(match(record: @pick, candidates: [@pick, @other]), task_returning(@pick.id))

          assert_equal [@pick.id, @other.id], verdict.payload["candidate_book_ids"]
        end

        test "default_finder is blinded and excludes no book" do
          captured = nil
          DataImporters::Books::Book::Finder.stubs(:new).with { |**args| captured = args }.returns(:finder)

          assert_equal :finder, MatchEdition.default_finder
          assert_equal :none, captured[:open_library]
          assert_not captured.key?(:exclude_ids)
          assert_equal DataImporters::Books::Book::Finder::TRUSTED_IDENTIFIER_SOURCES, captured[:identifier_sources]
          assert_equal DataImporters::Books::Book::Finder::TRUSTED_ALTERNATE_TITLE_SOURCES, captured[:alternate_title_sources]
        end

        def capturing_task(book_id, confidence = "high")
          captured = []
          task = stub(call: Services::Ai::Result.new(success: true, data: {book_id: book_id, confidence: confidence, reason: "r"}))
          klass = stub
          klass.stubs(:new).with { |args| captured.replace(args[:books]) }.returns(task)
          [klass, captured]
        end

        test "the reader's current book is offered to the AI even when the finder found nothing" do
          @edition.update!(book_id: @other.id)
          klass, captured = capturing_task(@other.id)

          result = run_match(match, klass)

          assert_equal [@other.id], captured.map(&:id)
          assert_equal :matched, result.data[:outcome]
          assert_equal [@other.id], verdict.payload["candidate_book_ids"]
        end

        test "the AI confirming the reader's current book at high when the finder found nothing is auto-approved" do
          @edition.update!(book_id: @other.id)
          run_match(match(candidates: [@pick]), task_returning(@other.id))

          assert verdict.approved?
          assert_equal @other.id, verdict.payload["book_id"]
        end

        test "the AI confirming a reader's current book that is a mixed book waits for review" do
          @edition.update!(book_id: @other.id)
          MixedBooks.stubs(:include?).with(@other.id).returns(true)
          run_match(match, task_returning(@other.id))

          assert verdict.proposed?
          assert_equal @other.id, verdict.payload["book_id"]
        end

        test "the AI picking the reader's current book over the finder's different pick waits for review" do
          @edition.update!(book_id: @other.id)
          run_match(match(record: @pick), task_returning(@other.id))

          assert verdict.proposed?
          assert_equal @other.id, verdict.payload["book_id"]
        end

        test "the current book already among the finder's candidates keeps its place and appears once" do
          @edition.update!(book_id: @other.id)
          klass, captured = capturing_task(@other.id)

          run_match(match(candidates: [@other, @pick]), klass)

          assert_equal [@other.id, @pick.id], captured.map(&:id)
          assert verdict.approved?
        end

        test "the AI picking the reader's current book at medium waits for review" do
          @edition.update!(book_id: @other.id)
          run_match(match, task_returning(@other.id, "medium"))

          assert verdict.proposed?
        end

        test "the AI saying none with an import-made current book offered: high creates, medium waits" do
          @edition.update!(book_id: derived_book.id)
          run_match(match, task_returning(nil, "high"))
          assert verdict.approved?
          assert_equal "create", verdict.payload["outcome"]

          verdict.destroy!
          run_match(match, task_returning(nil, "medium"))
          assert verdict.proposed?
        end

        test "the AI saying none at high when the reader is on a trusted book waits for review" do
          @edition.update!(book_id: @other.id)
          run_match(match, task_returning(nil, "high"))

          assert verdict.proposed?
          assert_equal "create", verdict.payload["outcome"]
        end

        test "the current book follows merges, counts once, and keeps a place in a full list" do
          extra = Array.new(7) { |i| ::Books::Book.create!(title: "Extra #{i}") }
          @edition.update!(book_id: @pick.id)
          GoodreadsReplay::Apply::MergedBook.stubs(:call).with(@pick.id).returns(@other)
          klass, captured = capturing_task(nil, "low")
          finder_match = DataImporters::Match.new(outcome: :unmatched, candidates: (extra + [@other]).map { |r| Cand.new(r) }, decided_by: :rule)

          run_match(finder_match, klass)

          assert_equal extra.first(5).map(&:id) + [@other.id], captured.map(&:id)
        end

        test "a none answer asks for the English title and matches the book the English search picks" do
          derived = derived_book
          finder = SeqFinder.new(match(candidates: [derived]), match(record: @pick))
          offered = []

          result = run_english(finder, tasks_returning(nil, @pick.id, offered: offered), english_returning("War and Peace"))

          assert_equal :matched, result.data[:outcome]
          assert verdict.approved?
          assert_equal @pick.id, verdict.payload["book_id"]
          assert_equal({"title" => "War and Peace", "confidence" => "high", "reason" => "translated"}, verdict.payload["english_title"])
          english_query = finder.queries.last
          assert_equal "War and Peace", english_query.title
          assert_empty english_query.isbn13
          assert_empty english_query.goodreads_id
          assert_equal [@pick.id, derived.id], offered.last[:books].map(&:id)
          assert_equal "War and Peace", offered.last[:english_title]
          assert_equal [@pick.id, derived.id], verdict.payload["candidate_book_ids"]
        end

        test "no candidates at all, a translated edition: the English search finds the book" do
          finder = SeqFinder.new(match, match(record: @pick))
          offered = []

          result = run_english(finder, tasks_returning(@pick.id, offered: offered), english_returning("War and Peace"))

          assert_equal :matched, result.data[:outcome]
          assert verdict.approved?
          assert_equal 1, offered.size
        end

        test "the AI picking a book the English search only listed waits for review" do
          finder = SeqFinder.new(match, match(candidates: [@pick]))

          run_english(finder, tasks_returning(@pick.id), english_returning("War and Peace"))

          assert verdict.proposed?
          assert_equal @pick.id, verdict.payload["book_id"]
        end

        test "the AI saying none after the English search: create, proposed when the English search picked a book" do
          finder = SeqFinder.new(match, match(record: @pick))

          result = run_english(finder, tasks_returning(nil), english_returning("War and Peace"))

          assert_equal :create, result.data[:outcome]
          assert verdict.proposed?
        end

        test "no English title: create as before, the same-work AI asked once" do
          offered = []
          run_english(SeqFinder.new(match(candidates: [derived_book])), tasks_returning(nil, offered: offered), english_returning(nil))

          assert verdict.approved?
          assert_equal "create", verdict.payload["outcome"]
          assert_nil verdict.payload["english_title"]["title"]
          assert_equal 1, offered.size
        end

        test "an English search that finds nothing new creates without asking the AI again" do
          derived = derived_book
          offered = []
          finder = SeqFinder.new(match(candidates: [derived]), match(candidates: [derived]))

          run_english(finder, tasks_returning(nil, offered: offered), english_returning("War and Peace"))

          assert_equal "create", verdict.payload["outcome"]
          assert_equal "War and Peace", verdict.payload["english_title"]["title"]
          assert_equal 1, offered.size
        end

        test "an English title failure or a failed English search records nothing and returns :retry" do
          assert_equal :retry, run_english(SeqFinder.new(match), tasks_returning, english_returning(nil, success: false)).data[:outcome]
          finder = SeqFinder.new(match, match(sources_failed: [:worldcat]))
          assert_equal :retry, run_english(finder, tasks_returning, english_returning("War and Peace")).data[:outcome]
          assert_not ::Books::RepairVerdict.exists?(subject_key: @key)
        end

        test "a matched answer never asks for an English title" do
          english = mock
          english.expects(:new).never

          run_english(SeqFinder.new(match(record: @pick)), tasks_returning(@pick.id), english)

          assert verdict.approved?
          assert_nil verdict.payload["english_title"]
        end

        def old_create(**attrs)
          ::Books::RepairVerdict.create!(kind: :reimport_match, subject_key: @key, payload: {"outcome" => "create"}, decided_by: :ai,
            status: :approved, confidence: :high, **attrs)
        end

        test "a recheck replaces an unreviewed create verdict with the English match" do
          old = old_create

          result = MatchEdition.call(edition: @edition, finder: SeqFinder.new(match, match(record: @pick)), task_class: tasks_returning(@pick.id),
            english_task_class: english_returning("War and Peace"), recheck: true)

          assert_equal :matched, result.data[:outcome]
          assert_equal old.id, verdict.id
          assert verdict.approved?
          assert_equal @pick.id, verdict.payload["book_id"]
          assert_equal "War and Peace", verdict.payload["english_title"]["title"]
        end

        test "without recheck an existing create verdict is kept" do
          old_create
          finder = mock
          finder.expects(:call).never

          assert_equal :kept, MatchEdition.call(edition: @edition, finder: finder).data[:outcome]
        end

        test "a recheck leaves a reviewed, applied or already checked verdict alone without searching" do
          [{reviewed_at: Time.current}, {applied_at: Time.current}, {payload: {"outcome" => "create", "english_title" => {}}}].each do |attrs|
            ::Books::RepairVerdict.where(subject_key: @key).delete_all
            old = old_create(**attrs)
            finder = mock
            finder.expects(:call).never

            assert_equal :kept, MatchEdition.call(edition: @edition, finder: finder, recheck: true).data[:outcome], attrs.keys.inspect
            assert_equal old.payload, old.reload.payload
          end
        end

        test "a recheck keeps a verdict reviewed or applied while its edition was being matched" do
          [{status: :rejected, reviewed_at: Time.current}, {applied_at: Time.current}].each do |change|
            ::Books::RepairVerdict.where(subject_key: @key).delete_all
            old = old_create
            english = stub
            english.stubs(:new).returns(stub.tap do |task|
              task.stubs(:call).with do
                old.update!(change)
                true
              end.returns(Services::Ai::Result.new(success: true, data: {title: "War and Peace", confidence: "high", reason: "r"}))
            end)

            result = MatchEdition.call(edition: @edition, finder: SeqFinder.new(match, match(record: @pick)), task_class: tasks_returning(@pick.id),
              english_task_class: english, recheck: true)

            assert_equal :kept, result.data[:outcome], change.keys.inspect
            assert_equal({"outcome" => "create"}, old.reload.payload, change.keys.inspect)
          end
        end
      end
    end
  end
end
