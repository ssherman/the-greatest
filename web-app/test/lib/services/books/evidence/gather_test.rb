require "test_helper"

module Services
  module Books
    module Evidence
      class GatherTest < ActiveSupport::TestCase
        setup do
          @book = books_books(:war_and_peace)
          @wikidata = mock("wikidata")
          @wikidata.stubs(:country_codes).returns({})
          @wikidata.stubs(:dump_date).returns("2026-11-05")
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

        test "its default Wikipedia client uses the evidence lane's longer inline wait, and Wikidata takes no http" do
          waits = []
          builder = ->(**kwargs) { waits << kwargs[:http].settings.max_inline_wait }
          ::Wikidata::Client.stubs(:new).with { |**kwargs| kwargs.empty? }.returns(@wikidata)
          ::Wikipedia::Client.stubs(:new).with { |**kwargs| builder.call(**kwargs) || true }.returns(@wikipedia)
          @wikidata.stubs(:find_work).returns(nil)
          ResolveWikidataWork.stubs(:call).returns(resolved(work: nil))
          @worldcat.stubs(:lookup).returns({})
          @worldcat.stubs(:records_by_oclc).returns({})

          Gather.call(book: @book, worldcat: @worldcat)

          assert_equal [30.0], waits
          assert_equal 5.0, Rails.application.config.x.wikimedia.max_inline_wait
        end

        test "evidence_http_settings copies every setting Http reads and leaves the shared config alone" do
          shared = Rails.application.config.x.wikimedia
          settings = Gather.evidence_http_settings

          assert_equal [shared.evidence_max_inline_wait, shared.requests_per_window, shared.window_seconds, shared.maxlag, shared.contact],
            [settings.max_inline_wait, settings.requests_per_window, settings.window_seconds, settings.maxlag, settings.contact]
          assert_not_same shared, settings
          assert_equal 5.0, shared.max_inline_wait
        end

        def gather
          Gather.call(book: @book, wikidata: @wikidata, wikipedia: @wikipedia, worldcat: @worldcat)
        end

        test "a full hit writes one row with all three sections and English labels" do
          ResolveWikidataWork.expects(:call).with(book: @book, client: @wikidata).returns(resolved)
          @wikidata.expects(:labels).once.returns({"Q159" => "Russian Empire", "Q7737" => "Russian", "Q8261" => "novel"})
          @wikidata.stubs(:country_codes).returns("Q159" => {"code" => "RU", "label" => "Russia"})
          @wikipedia.expects(:article).with(language: "en", title: "War and Peace").returns(@article)
          WorldCatSection.expects(:call).with(book: @book, client: @worldcat).returns(@section)

          result = nil
          assert_difference -> { @book.enrichments.for_kind("books.evidence").count }, 1 do
            result = gather
          end

          assert result.success?
          row = result.data[:enrichment]
          assert row.applied?
          facts = row.facts
          assert_equal 3, facts["schema_version"]
          assert_equal ["Russian Empire"], facts["wikidata"]["countries"]
          assert_equal ["Russian"], facts["wikidata"]["languages"]
          assert_equal "Q161531", facts["wikidata"]["qid"]
          assert_equal "Q161531", facts["wikidata_qid"]
          assert_equal %w[qid via label description countries languages genres main_subjects narrative_locations
            set_in_periods forms publication_years enwiki_title country_ids country_matches].sort, facts["wikidata"].keys.sort
          assert_equal %w[title url lead plot infobox].sort, facts["wikipedia"].keys.sort
          assert_equal({}, facts["source_errors"])
          assert_equal "A plot", facts["wikipedia"]["plot"]
          assert_equal @section, facts["worldcat"]
          assert_equal [{"id" => "Q1", "reason" => "x"}], facts["wikidata_rejected"]
          assert_nil facts["wikidata_conflict_book_id"]
          assert_equal [], facts["sources_failed"]
        end

        test "the wikidata section carries P495 ids and the countries they map to" do
          work = ::Wikidata::Work.from_payload(
            "id" => "Q161531", "label" => "Le Livre", "countries" => ["Q142"], "languages" => [], "genres" => [],
            "main_subjects" => [], "narrative_locations" => [], "set_in_periods" => [], "forms" => [],
            "publication_years" => [], "enwiki_title" => nil
          )
          ResolveWikidataWork.expects(:call).returns(resolved(work: work))
          @wikidata.stubs(:labels).returns({"Q142" => "France"})
          @wikidata.expects(:country_codes).with(["Q142"]).returns("Q142" => {"code" => "FR", "label" => "France"})
          WorldCatSection.expects(:call).returns(nil)

          facts = gather.data[:enrichment].facts

          assert_equal 3, facts["schema_version"]
          assert_equal ["Q142"], facts["wikidata"]["country_ids"]
          assert_equal ["French"], facts["wikidata"]["country_matches"]
        end

        test "a Wikidata error while mapping countries fails the wikidata source" do
          ResolveWikidataWork.expects(:call).returns(resolved)
          @wikidata.stubs(:labels).returns({})
          @wikidata.expects(:country_codes).raises(Wikimedia::Exceptions::NetworkError.new("down"))
          WorldCatSection.expects(:call).returns(nil)

          row = gather.data[:enrichment]

          assert_equal ["wikidata"], row.facts["sources_failed"]
          assert_nil row.facts["wikidata"]
        end

        test "the row records the Wikidata dump date" do
          ResolveWikidataWork.expects(:call).returns(resolved)
          @wikidata.stubs(:labels).returns({})
          @wikipedia.stubs(:article).returns(@article)
          WorldCatSection.expects(:call).returns(nil)

          assert_equal "2026-11-05", gather.data[:enrichment].facts["wikidata_dump_date"]
        end

        test "an unavailable Wikidata service propagates and writes nothing" do
          ResolveWikidataWork.expects(:call).raises(Wikidata::Exceptions::Unavailable.new("down", retry_after: 60))

          assert_no_difference -> { Enrichment.count } do
            assert_raises(Wikidata::Exceptions::Unavailable) { gather }
          end
        end

        test "a rate limit while mapping countries propagates and writes nothing" do
          ResolveWikidataWork.expects(:call).returns(resolved)
          @wikidata.stubs(:labels).returns({})
          @wikidata.expects(:country_codes).raises(Wikimedia::Exceptions::RateLimited.new("slow", retry_after: 5))

          assert_no_difference -> { Enrichment.count } do
            assert_raises(Wikimedia::Exceptions::RateLimited) { gather }
          end
        end

        test "a conflict records the other book's id" do
          data = resolved(work: nil).data.merge(conflict_book_id: 42)
          ResolveWikidataWork.expects(:call).returns(ResolveWikidataWork::Result.new(success?: true, errors: [], data: data))
          WorldCatSection.expects(:call).returns(nil)

          assert_equal 42, gather.data[:enrichment].facts["wikidata_conflict_book_id"]
        end

        test "a Wikidata network error in resolution fails wikidata, never asks Wikipedia and keeps WorldCat" do
          ResolveWikidataWork.expects(:call).raises(Wikimedia::Exceptions::NetworkError.new("down"))
          @wikipedia.expects(:article).never
          WorldCatSection.expects(:call).returns(@section)

          row = gather.data[:enrichment]

          assert_equal ["wikidata"], row.facts["sources_failed"]
          assert_equal [], row.facts["wikidata_rejected"]
          assert_nil row.facts["wikidata_qid"]
          assert_equal @section, row.facts["worldcat"]
          assert_match(/NetworkError: down/, row.facts["source_errors"]["wikidata"])
        end

        test "a failed source is logged with the book id" do
          ResolveWikidataWork.expects(:call).returns(resolved(work: nil))
          WorldCatSection.expects(:call).raises(::Books::WorldCat::Exceptions::CircuitOpenError.new("open"))
          Rails.logger.expects(:warn).with(regexp_matches(/book #{@book.id}: worldcat failed/))

          gather
        end

        test "the QID is recorded even when the labels call fails" do
          ResolveWikidataWork.expects(:call).returns(resolved)
          @wikidata.expects(:labels).raises(Wikimedia::Exceptions::NetworkError.new("down"))
          WorldCatSection.stubs(:call).returns(nil)

          facts = gather.data[:enrichment].facts

          assert_nil facts["wikidata"]
          assert_equal "Q161531", facts["wikidata_qid"]
          assert_match(/NetworkError: down/, facts["source_errors"]["wikidata"])
        end

        test "a Wikipedia error is described in source_errors, truncated to 200 characters" do
          ResolveWikidataWork.expects(:call).returns(resolved)
          @wikidata.stubs(:labels).returns({})
          @wikipedia.expects(:article).raises(Wikimedia::Exceptions::NetworkError.new("x" * 500))
          WorldCatSection.stubs(:call).returns(nil)

          assert_equal 200, gather.data[:enrichment].facts["source_errors"]["wikipedia"].length
        end

        test "a WorldCat client that cannot be built fails worldcat, not the step" do
          ResolveWikidataWork.expects(:call).returns(resolved(work: nil))
          ::Books::WorldCat::Client.expects(:new).raises(::Books::WorldCat::Exceptions::ConfigurationError.new("no base url"))

          row = Gather.call(book: @book, wikidata: @wikidata, wikipedia: @wikipedia).data[:enrichment]

          assert_equal ["worldcat"], row.facts["sources_failed"]
          assert_nil row.facts["worldcat"]
          assert_match(/ConfigurationError: no base url/, row.facts["source_errors"]["worldcat"])
        end

        test "a rate limit from labels propagates and writes nothing" do
          ResolveWikidataWork.expects(:call).returns(resolved)
          @wikidata.expects(:labels).raises(Wikimedia::Exceptions::RateLimited.new("slow down", retry_after: 1))
          WorldCatSection.stubs(:call).returns(nil)

          assert_no_difference -> { @book.enrichments.for_kind("books.evidence").count } do
            assert_raises(Wikimedia::Exceptions::RateLimited) { gather }
          end
        end

        test "a rate limit from article propagates and writes nothing" do
          ResolveWikidataWork.expects(:call).returns(resolved)
          @wikidata.stubs(:labels).returns({})
          @wikipedia.expects(:article).raises(Wikimedia::Exceptions::RateLimited.new("slow down", retry_after: 1))
          WorldCatSection.stubs(:call).returns(nil)

          assert_no_difference -> { @book.enrichments.for_kind("books.evidence").count } do
            assert_raises(Wikimedia::Exceptions::RateLimited) { gather }
          end
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
