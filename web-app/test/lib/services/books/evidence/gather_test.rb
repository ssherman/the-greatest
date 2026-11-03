require "test_helper"

module Services
  module Books
    module Evidence
      class GatherTest < ActiveSupport::TestCase
        setup do
          @book = books_books(:war_and_peace)
          @wikidata = mock("wikidata")
          @wikipedia = mock("wikipedia")
          @worldcat = mock("worldcat")
          @work = ::Wikidata::Work.from_payload(
            "id" => "Q161531", "label" => "War and Peace", "description" => "novel",
            "countries" => ["Q159"], "languages" => ["Q7737", "Q999"], "genres" => [],
            "main_subjects" => [], "narrative_locations" => [], "set_in_periods" => [],
            "forms" => ["Q8261"], "publication_years" => [1869], "enwiki_title" => "War and Peace"
          )
          @article = ::Wikipedia::Article.new(title: "War and Peace", url: "https://en.wikipedia.org/wiki/War_and_Peace",
            page_id: 1, lead: "A lead", plot: "A plot", infobox: {"author" => "Tolstoy"})
          @section = {"isbns_accepted" => ["9780140447934"]}
        end

        def resolved(work: @work)
          ResolveWikidataWork::Result.new(success?: true, errors: [],
            data: {qid: work&.id, via: "stored", work: work, conflict_book_id: nil, rejected: [{"id" => "Q1", "reason" => "x"}]})
        end

        def gather
          Gather.call(book: @book, wikidata: @wikidata, wikipedia: @wikipedia, worldcat: @worldcat)
        end

        test "a full hit writes one row with all three sections and English labels" do
          ResolveWikidataWork.expects(:call).returns(resolved)
          @wikidata.expects(:labels).once.returns({"Q159" => "Russian Empire", "Q7737" => "Russian", "Q8261" => "novel"})
          @wikipedia.expects(:article).with(language: "en", title: "War and Peace").returns(@article)
          WorldCatSection.expects(:call).returns(@section)

          result = nil
          assert_difference -> { @book.enrichments.for_kind("books.evidence").count }, 1 do
            result = gather
          end

          assert result.success?
          row = result.data[:enrichment]
          assert row.applied?
          facts = row.facts
          assert_equal 1, facts["schema_version"]
          assert_equal ["Russian Empire"], facts["wikidata"]["countries"]
          assert_equal ["Russian"], facts["wikidata"]["languages"]
          assert_equal "Q161531", facts["wikidata"]["qid"]
          assert_equal "A plot", facts["wikipedia"]["plot"]
          assert_equal @section, facts["worldcat"]
          assert_equal [{"id" => "Q1", "reason" => "x"}], facts["wikidata_rejected"]
          assert_nil facts["wikidata_conflict_book_id"]
          assert_equal [], facts["sources_failed"]
        end

        test "nothing found records nothing_to_apply with every section nil" do
          ResolveWikidataWork.expects(:call).returns(resolved(work: nil))
          WorldCatSection.expects(:call).returns(nil)

          row = gather.data[:enrichment]

          assert row.nothing_to_apply?
          assert_nil row.facts["wikidata"]
          assert_nil row.facts["wikipedia"]
          assert_nil row.facts["worldcat"]
        end

        test "a rate limit propagates and writes nothing" do
          ResolveWikidataWork.expects(:call).raises(Wikimedia::Exceptions::RateLimited.new("slow down", retry_after: 1))
          WorldCatSection.stubs(:call).returns(nil)

          assert_no_difference -> { @book.enrichments.for_kind("books.evidence").count } do
            assert_raises(Wikimedia::Exceptions::RateLimited) { gather }
          end
        end

        test "a WorldCat failure marks that source failed and keeps the others" do
          ResolveWikidataWork.expects(:call).returns(resolved)
          @wikidata.stubs(:labels).returns({"Q159" => "Russian Empire"})
          @wikipedia.stubs(:article).returns(@article)
          WorldCatSection.expects(:call).raises(::Books::WorldCat::Exceptions::CircuitOpenError.new("open"))

          row = gather.data[:enrichment]

          assert_equal ["worldcat"], row.facts["sources_failed"]
          assert_nil row.facts["worldcat"]
          assert_equal "Q161531", row.facts["wikidata"]["qid"]
          assert_equal "War and Peace", row.facts["wikipedia"]["title"]
          assert row.applied?
        end

        test "a missing Wikipedia article is nil, not a failure" do
          ResolveWikidataWork.expects(:call).returns(resolved)
          @wikidata.stubs(:labels).returns({})
          @wikipedia.expects(:article).returns(nil)
          WorldCatSection.stubs(:call).returns(nil)

          row = gather.data[:enrichment]

          assert_nil row.facts["wikipedia"]
          assert_equal [], row.facts["sources_failed"]
        end

        test "no enwiki title skips Wikipedia without calling it" do
          work = ::Wikidata::Work.from_payload("id" => "Q1", "countries" => [])
          ResolveWikidataWork.expects(:call).returns(resolved(work: work))
          @wikidata.stubs(:labels).returns({})
          @wikipedia.expects(:article).never
          WorldCatSection.stubs(:call).returns(nil)

          row = gather.data[:enrichment]

          assert_nil row.facts["wikipedia"]
          assert_equal [], row.facts["sources_failed"]
        end

        test "a Wikidata API error fails wikidata, skips Wikipedia, keeps rejections" do
          ResolveWikidataWork.expects(:call).returns(resolved)
          @wikidata.expects(:labels).raises(Wikimedia::Exceptions::NetworkError.new("down"))
          @wikipedia.expects(:article).never
          WorldCatSection.stubs(:call).returns(@section)

          row = gather.data[:enrichment]

          assert_nil row.facts["wikidata"]
          assert_equal ["wikidata"], row.facts["sources_failed"]
          assert_equal [{"id" => "Q1", "reason" => "x"}], row.facts["wikidata_rejected"]
          assert_equal @section, row.facts["worldcat"]
        end

        test "a Wikipedia API error fails wikipedia only" do
          ResolveWikidataWork.expects(:call).returns(resolved)
          @wikidata.stubs(:labels).returns({})
          @wikipedia.expects(:article).raises(Wikimedia::Exceptions::HttpError.new("500", 500))
          WorldCatSection.stubs(:call).returns(nil)

          row = gather.data[:enrichment]

          assert_equal ["wikipedia"], row.facts["sources_failed"]
          assert_equal "Q161531", row.facts["wikidata"]["qid"]
        end

        test "inside a workflow step the row links to the step" do
          step = workflow_steps(:tolstoy_wikidata)
          ResolveWikidataWork.expects(:call).returns(resolved(work: nil))
          WorldCatSection.stubs(:call).returns(nil)

          Current.workflow_step_id = step.id
          row = gather.data[:enrichment]

          assert_equal step.id, row.workflow_step_id
        ensure
          Current.reset
        end
      end
    end
  end
end
