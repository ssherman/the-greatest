require "test_helper"

module Services
  module Books
    module BookSubmissions
      class ResolveInputTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        ISBN13 = "9780061054884"
        WC = ::Books::WorldCat
        OL = ::Books::OpenLibrary

        def setup
          @user = users(:regular_user)
        end

        # ---- builders --------------------------------------------------

        def submission(method, **attributes)
          raw = (method.to_s == "title_authors") ? {} : {raw_input: "pasted"}
          ::Books::BookSubmission.create!({user: @user, input_method: method}.merge(raw).merge(attributes))
        end

        def isbn_submission(**attributes) = submission(:isbn, isbn13: ISBN13, **attributes)

        def amazon_submission(**attributes) = submission(:amazon, asin: "B000FC11JE", **attributes)

        def wc_record(title: "The dispossessed : an ambiguous utopia / Ursula K. Le Guin.", creator: "Le Guin, Ursula K., 1929-2018.",
          contributors: [], year: "1974", holding_count: 100, oclc: 1, subtitle: nil)
          WC::Record.from_hash({"oclc" => oclc, "title" => title, "subtitle" => subtitle, "creator" => creator,
            "contributors" => contributors, "year" => year, "holdings" => {"total_holding_count" => holding_count}})
        end

        def ol_work(key: "OL1W", title: "The Dispossessed", subtitle: nil, authors: ["Ursula K. Le Guin"])
          OL::Work.new(key: key, source: "ol", title: title, subtitle: subtitle, description: nil, author_keys: [],
            author_names: authors, subjects: [], year_evidence: nil, popularity: nil, redirected_from: [], source_version: nil)
        end

        def ol_hit(key)
          OL::IdentifierHit.new(work_key: key, source: "ol", redirected_from: [], edition_keys: [], id_type: "isbn13", value: ISBN13)
        end

        def amazon_product(title: "The Dispossessed (Hainish Cycle) : An Ambiguous Utopia", authors: ["Ursula K. Le Guin"],
          isbns: [ISBN13, "0061054887"], eans: [], year: "2009-10-13", asin: "B000FC11JE")
          {"asin" => asin, "itemInfo" => {
            "title" => {"displayValue" => title},
            "byLineInfo" => {"contributors" => authors.map { |name| {"name" => name, "role" => "Author"} }},
            "contentInfo" => {"publicationDate" => {"displayValue" => year}},
            "externalIds" => {"isbns" => {"displayValues" => isbns}, "eans" => {"displayValues" => eans}}
          }}
        end

        def toaster = amazon_product(title: "Four Slice Toaster", authors: [], isbns: [], eans: ["0123456789012"])

        def stub_world_cat(result)
          stub = ::Books::WorldCat::Client.any_instance.stubs(:record_by_isbn).with(ISBN13)
          result.is_a?(Exception) ? stub.raises(result) : stub.returns(result)
        end

        def stub_open_library(hits: [], work: nil, error: nil)
          client = ::Books::OpenLibrary::Client.any_instance
          error ? client.stubs(:identifier).raises(error) : client.stubs(:identifier).with("isbn13", ISBN13).returns(hits)
          client.stubs(:work).returns(work) if work
        end

        def stub_amazon_search(items = [], error: nil)
          stub = ::Services::Amazon::Client.stubs(:search_items)
          error ? stub.raises(error) : stub.returns(items)
        end

        def resolve(submission) = ResolveInput.call(submission: submission)

        def down(klass = WC::Exceptions::ServerError)
          (klass <= WC::Exceptions::HttpError || klass <= OL::Exceptions::HttpError) ? klass.new("down", 503) : klass.new("down")
        end

        # ---- supplied --------------------------------------------------

        test "supplied facts win over the input method and call nothing outside" do
          ::Books::WorldCat::Client.any_instance.expects(:record_by_isbn).never
          ::Services::Amazon::Client.expects(:get_items).never
          sub = isbn_submission(supplied: {
            "title" => "  The   Dispossessed ", "author_names" => ["Ursula K. Le Guin", " "], "subtitle" => "An Ambiguous Utopia",
            "year" => 1974, "identifiers" => {"isbn13" => [ISBN13], "asin" => ["B000FC11JE"], "bogus" => ["x"]}
          })

          result = resolve(sub)

          assert result.success?
          assert_equal :resolved, result.data[:outcome]
          assert_equal "supplied", result.data[:source]
          assert_equal "The Dispossessed", result.data[:title]
          assert_equal "An Ambiguous Utopia", result.data[:subtitle]
          assert_equal ["Ursula K. Le Guin"], result.data[:author_names]
          assert_equal 1974, result.data[:year]
          assert_equal({isbn13: [ISBN13], isbn10: [], asin: ["B000FC11JE"], goodreads_id: []}, result.data[:identifiers])
        end

        test "supplied without a usable title and author is ignored" do
          sub = isbn_submission(supplied: {"title" => "Only a title", "author_names" => []})
          stub_world_cat([wc_record])

          assert_equal "worldcat", resolve(sub).data[:source]
        end

        test "an empty supplied hash is ignored" do
          sub = isbn_submission(supplied: {})
          stub_world_cat([wc_record])

          assert_equal "worldcat", resolve(sub).data[:source]
        end

        # ---- title_authors ---------------------------------------------

        test "title_authors resolves as typed with no identifiers and calls nothing outside" do
          ::Books::WorldCat::Client.any_instance.expects(:record_by_isbn).never
          ::Books::OpenLibrary::Client.any_instance.expects(:identifier).never
          ::Services::Amazon::Client.expects(:search_items).never
          sub = submission(:title_authors, typed_title: "  A  Quiet   Year ", typed_author_names: ["Anna  Brenner", "B. Two"])

          result = resolve(sub)

          assert_equal :resolved, result.data[:outcome]
          assert_equal "title_authors", result.data[:source]
          assert_equal "A Quiet Year", result.data[:title]
          assert_equal ["Anna Brenner", "B. Two"], result.data[:author_names]
          assert_nil result.data[:subtitle]
          assert_nil result.data[:year]
          assert_equal({isbn13: [], isbn10: [], asin: [], goodreads_id: []}, result.data[:identifiers])
        end

        test "titles are capped at 255 characters and authors at 10 of 255" do
          sub = submission(:title_authors, typed_title: "T", typed_author_names: ["A"])
          sub.assign_attributes(typed_title: "x" * 300, typed_author_names: (1..12).map { |n| "#{n}#{"y" * 300}" })

          result = ResolveInput.call(submission: sub.tap { |s| s.save!(validate: false) })

          assert_equal 255, result.data[:title].length
          assert_equal 10, result.data[:author_names].size
          assert result.data[:author_names].all? { |name| name.length == 255 }
        end

        # ---- goodreads -------------------------------------------------

        test "goodreads uses a conclusive page: creators only, with the year and its own id" do
          goodreads_page(goodreads_book_id: 4001, title: "The Quiet Year",
            authors: [["Anna Brenner", "Author"], ["Ivo Illustrator", "Illustrator"], ["Tess Translator", "Translator"]],
            original_publication_year: 1999)

          result = resolve(submission(:goodreads, goodreads_book_id: 4001))

          assert_equal :resolved, result.data[:outcome]
          assert_equal "goodreads", result.data[:source]
          assert_equal "The Quiet Year", result.data[:title]
          assert_equal ["Anna Brenner"], result.data[:author_names]
          assert_equal 1999, result.data[:year]
          assert_equal ["4001"], result.data[:identifiers][:goodreads_id]
        end

        test "goodreads takes every contributor when none is a creator" do
          goodreads_page(goodreads_book_id: 4002, authors: [["Ed Itor", "Editor"], ["Una Known", nil]])

          assert_equal ["Ed Itor", "Una Known"], resolve(submission(:goodreads, goodreads_book_id: 4002)).data[:author_names]
        end

        test "goodreads with no page asks for one" do
          result = resolve(submission(:goodreads, goodreads_book_id: 4003))

          assert_equal :needs_goodreads_page, result.data[:outcome]
        end

        test "goodreads with a blocked page asks for one again" do
          goodreads_page(goodreads_book_id: 4004, outcome: :blocked)

          assert_equal :needs_goodreads_page, resolve(submission(:goodreads, goodreads_book_id: 4004)).data[:outcome]
        end

        test "goodreads not_found is no_record, not a request for another page" do
          goodreads_page(goodreads_book_id: 4005, outcome: :not_found)

          assert_equal :no_record, resolve(submission(:goodreads, goodreads_book_id: 4005)).data[:outcome]
        end

        test "goodreads page with no title is no_record" do
          goodreads_page(goodreads_book_id: 4006, title: "")

          assert_equal :no_record, resolve(submission(:goodreads, goodreads_book_id: 4006)).data[:outcome]
        end

        # ---- amazon ----------------------------------------------------

        test "amazon asks for the asin with the book resources and splits the title" do
          ::Services::Amazon::Client.expects(:get_items)
            .with(item_ids: ["B000FC11JE"], resources: ::Services::Books::AmazonProductService::AMAZON_RESOURCES)
            .returns([amazon_product])
          sub = amazon_submission(isbn13: ISBN13, isbn10: "0061054887")

          result = resolve(sub)

          assert_equal :resolved, result.data[:outcome]
          assert_equal "amazon", result.data[:source]
          assert_equal "The Dispossessed", result.data[:title]
          assert_equal "An Ambiguous Utopia", result.data[:subtitle]
          assert_equal ["Ursula K. Le Guin"], result.data[:author_names]
          assert_equal 2009, result.data[:year]
          assert_equal({isbn13: [ISBN13], isbn10: ["0061054887"], asin: ["B000FC11JE"], goodreads_id: []}, result.data[:identifiers])
        end

        test "amazon returns only identifiers the submission carried" do
          ::Services::Amazon::Client.stubs(:get_items).returns([amazon_product(isbns: [ISBN13, "0061054887"], eans: ["9780000000002"])])

          identifiers = resolve(amazon_submission).data[:identifiers]

          assert_equal({isbn13: [], isbn10: [], asin: ["B000FC11JE"], goodreads_id: []}, identifiers)
        end

        test "an amazon product with no authors is no_record" do
          ::Services::Amazon::Client.stubs(:get_items).returns([toaster])

          result = resolve(amazon_submission)

          assert_equal :no_record, result.data[:outcome]
        end

        test "amazon with no item is no_record" do
          ::Services::Amazon::Client.stubs(:get_items).returns([])

          assert_equal :no_record, resolve(amazon_submission).data[:outcome]
        end

        test "amazon down is unavailable when there is no isbn to try" do
          ::Services::Amazon::Client.stubs(:get_items).raises(::Services::Amazon::Client::Error, "Amazon Creators API responded 503")

          result = resolve(amazon_submission)

          refute result.success?
          assert_equal :unavailable, result.data[:outcome]
        end

        test "amazon with no usable record goes on to the isbn chain when the submission has an isbn13" do
          ::Services::Amazon::Client.stubs(:get_items).returns([toaster])
          stub_world_cat([wc_record])

          result = resolve(amazon_submission(isbn13: ISBN13))

          assert_equal :resolved, result.data[:outcome]
          assert_equal "worldcat", result.data[:source]
          assert_equal [ISBN13], result.data[:identifiers][:isbn13]
          assert_equal ["B000FC11JE"], result.data[:identifiers][:asin]
        end

        test "amazon raising also goes on to the isbn chain" do
          ::Services::Amazon::Client.stubs(:get_items).raises(::Services::Amazon::Client::Error, "down")
          stub_world_cat([wc_record])

          assert_equal "worldcat", resolve(amazon_submission(isbn13: ISBN13)).data[:source]
        end

        test "amazon with an unusable record and an isbn chain that is down is unavailable" do
          ::Services::Amazon::Client.stubs(:get_items).returns([toaster])
          stub_world_cat(down)
          stub_open_library(error: down(OL::Exceptions::TimeoutError))
          stub_amazon_search(error: ::Services::Amazon::Client::Error.new("down"))

          assert_equal :unavailable, resolve(amazon_submission(isbn13: ISBN13)).data[:outcome]
        end

        test "amazon without an isbn13 never starts the isbn chain" do
          ::Services::Amazon::Client.stubs(:get_items).returns([toaster])
          ::Books::WorldCat::Client.any_instance.expects(:record_by_isbn).never

          assert_equal :no_record, resolve(amazon_submission(isbn10: "0061054887")).data[:outcome]
        end

        # ---- isbn: WorldCat --------------------------------------------

        test "isbn takes WorldCat first, cleans the name and splits the title" do
          stub_world_cat([wc_record])
          ::Books::OpenLibrary::Client.any_instance.expects(:identifier).never

          result = resolve(isbn_submission)

          assert_equal :resolved, result.data[:outcome]
          assert_equal "worldcat", result.data[:source]
          assert_equal "The dispossessed", result.data[:title]
          assert_equal "an ambiguous utopia", result.data[:subtitle]
          assert_equal ["Ursula K. Le Guin"], result.data[:author_names]
          assert_equal 1974, result.data[:year]
          assert_equal [ISBN13], result.data[:identifiers][:isbn13]
        end

        test "WorldCat names come out right" do
          {
            "Le Guin, Ursula K., 1929-2018." => "Ursula K. Le Guin",
            "King, Martin Luther, Jr., 1929-1968." => "Martin Luther King Jr.",
            "Homer." => "Homer",
            "Homer" => "Homer",
            "Chaucer, Geoffrey, approximately 1340-1400." => "Geoffrey Chaucer",
            "Homer, active 8th century B.C." => "Homer",
            "Hemingway, Ernest, 1899-" => "Ernest Hemingway",
            "Tolstoy, Leo, graf, 1828-1910." => "Leo Tolstoy",
            "Austen, Jane, 1775-1817 (Author)" => "Jane Austen",
            "Hemingway, Ernest 1899-1961." => "Ernest Hemingway",
            "Smith, John (Novelist)" => "John Smith",
            "Ursula K. Le Guin" => "Ursula K. Le Guin",
            "Dumas, Alexandre, 1802-1870 " => "Alexandre Dumas"
          }.each do |raw, expected|
            stub_world_cat([wc_record(creator: raw)])

            assert_equal [expected], resolve(isbn_submission).data[:author_names], raw
          end
        end

        test "a creator given as a Hash with a name is read" do
          stub_world_cat([wc_record(creator: {"name" => "Le Guin, Ursula K., 1929-2018."})])

          assert_equal ["Ursula K. Le Guin"], resolve(isbn_submission).data[:author_names]
        end

        test "contributors are used only when there is no creator" do
          stub_world_cat([wc_record(creator: nil, contributors: ["Orwell, George, 1903-1950.", {"name" => "Fyvel, T. R."}])])

          assert_equal ["George Orwell", "T. R. Fyvel"], resolve(isbn_submission).data[:author_names]
        end

        test "contributors are ignored when there is a creator" do
          stub_world_cat([wc_record(contributors: ["Illustrator, Ivo"])])

          assert_equal ["Ursula K. Le Guin"], resolve(isbn_submission).data[:author_names]
        end

        test "WorldCat prefers a usable record with the most holdings, deterministically" do
          records = [
            wc_record(title: "Wrong and unusable", creator: nil, holding_count: 9000, oclc: 1),
            wc_record(title: "Fewer holdings", holding_count: 10, oclc: 2),
            wc_record(title: "Most holdings", holding_count: 500, oclc: 3),
            wc_record(title: "Tie later oclc", holding_count: 500, oclc: 4)
          ]

          [records, records.reverse].each do |ordered|
            stub_world_cat(ordered)
            assert_equal "Most holdings", resolve(isbn_submission).data[:title]
          end
        end

        test "WorldCat records with no holding count rank last" do
          stub_world_cat([wc_record(title: "Unknown holdings", holding_count: nil, oclc: 1), wc_record(title: "Known", holding_count: 1, oclc: 2)])

          assert_equal "Known", resolve(isbn_submission).data[:title]
        end

        # ---- isbn: chain and outcomes ----------------------------------

        test "WorldCat down and Open Library answering is resolved" do
          stub_world_cat(down)
          stub_open_library(hits: [ol_hit("OL1W")], work: ol_work(subtitle: "An Ambiguous Utopia"))

          result = resolve(isbn_submission)

          assert_equal :resolved, result.data[:outcome]
          assert_equal "open_library", result.data[:source]
          assert_equal "The Dispossessed", result.data[:title]
          assert_equal "An Ambiguous Utopia", result.data[:subtitle]
          assert_equal ["Ursula K. Le Guin"], result.data[:author_names]
        end

        test "WorldCat with only unusable records falls through to Open Library" do
          stub_world_cat([wc_record(creator: nil), wc_record(title: " ")])
          stub_open_library(hits: [ol_hit("OL1W")], work: ol_work)

          assert_equal "open_library", resolve(isbn_submission).data[:source]
        end

        test "Open Library hits on two different works are not usable" do
          stub_world_cat([])
          stub_open_library(hits: [ol_hit("OL1W"), ol_hit("OL2W")], work: ol_work)
          stub_amazon_search([])

          assert_equal :no_record, resolve(isbn_submission).data[:outcome]
        end

        test "Open Library hits on the same work twice are one work" do
          stub_world_cat([])
          stub_open_library(hits: [ol_hit("OL1W"), ol_hit("OL1W")], work: ol_work)

          assert_equal "open_library", resolve(isbn_submission).data[:source]
        end

        test "Open Library work with no authors is not usable" do
          stub_world_cat([])
          stub_open_library(hits: [ol_hit("OL1W")], work: ol_work(authors: []))
          stub_amazon_search([])

          assert_equal :no_record, resolve(isbn_submission).data[:outcome]
        end

        test "Open Library with no hit goes on to Amazon, which must carry the isbn" do
          stub_world_cat([])
          stub_open_library(hits: [])
          ::Services::Amazon::Client.expects(:search_items)
            .with(keywords: ISBN13, search_index: "Books", resources: ::Services::Books::AmazonProductService::AMAZON_RESOURCES)
            .returns([amazon_product(title: "A Different Book", isbns: ["9781111111111"], asin: "B000OTHER0"), amazon_product])

          result = resolve(isbn_submission)

          assert_equal "amazon", result.data[:source]
          assert_equal "The Dispossessed", result.data[:title]
        end

        test "Amazon search keeping no product with the isbn is no_record" do
          stub_world_cat([])
          stub_open_library(hits: [])
          stub_amazon_search([amazon_product(isbns: ["9781111111111"])])

          assert_equal :no_record, resolve(isbn_submission).data[:outcome]
        end

        test "an isbn that nobody has is no_record when every source says so, a 404 included" do
          stub_world_cat(down(WC::Exceptions::NotFoundError))
          stub_open_library(error: down(OL::Exceptions::NotFoundError))
          stub_amazon_search([])

          result = resolve(isbn_submission)

          assert result.success?
          assert_equal :no_record, result.data[:outcome]
        end

        test "all three sources down is unavailable" do
          stub_world_cat(down(WC::Exceptions::TimeoutError))
          stub_open_library(error: down(OL::Exceptions::CircuitOpenError))
          stub_amazon_search(error: ::Services::Amazon::Client::Error.new("not configured"))

          result = resolve(isbn_submission)

          refute result.success?
          assert_equal :unavailable, result.data[:outcome]
          assert_predicate result.errors, :any?
        end

        test "two sources empty and one down is unavailable" do
          stub_world_cat([])
          stub_open_library(hits: [])
          stub_amazon_search(error: ::Services::Amazon::Client::Error.new("503"))

          assert_equal :unavailable, resolve(isbn_submission).data[:outcome]
        end

        test "an http library error from Amazon counts as that source raising" do
          stub_world_cat([])
          stub_open_library(hits: [])
          stub_amazon_search(error: ::HTTP::TimeoutError.new("timed out"))

          assert_equal :unavailable, resolve(isbn_submission).data[:outcome]
        end

        test "an ISBN answered by the first source stops the chain" do
          stub_world_cat([wc_record])
          ::Services::Amazon::Client.expects(:search_items).never

          assert_equal :resolved, resolve(isbn_submission).data[:outcome]
        end

        # ---- errors that are not a source being down -------------------

        test "a database error propagates" do
          stub_world_cat([wc_record])
          sub = isbn_submission
          sub.stubs(:update_column).raises(ActiveRecord::StatementInvalid, "boom")

          assert_raises(ActiveRecord::StatementInvalid) { resolve(sub) }
        end

        test "a programming error in a source propagates and is not mistaken for a source being down" do
          ::Books::WorldCat::Client.any_instance.stubs(:record_by_isbn).raises(NoMethodError, "undefined method")

          assert_raises(NoMethodError) { resolve(isbn_submission) }
        end

        # ---- lookup ----------------------------------------------------

        test "lookup records what each source answered, including errors" do
          stub_world_cat(down(WC::Exceptions::TimeoutError))
          stub_open_library(hits: [])
          stub_amazon_search([amazon_product])
          sub = isbn_submission

          resolve(sub)

          entries = sub.reload.lookup
          assert_equal %w[worldcat open_library amazon], entries.map { |entry| entry["source"] }
          assert_equal %w[error empty resolved], entries.map { |entry| entry["outcome"] }
          assert_equal "Books::WorldCat::Exceptions::TimeoutError", entries.first["error_class"]
          assert_equal "down", entries.first["error_message"]
          assert_equal ["Ursula K. Le Guin"], entries.last["author_names"]
          assert_equal "The Dispossessed", entries.last["title"]
          assert_equal 2009, entries.last["year"]
        end

        test "a definite no such record is recorded as empty, not as an error" do
          stub_world_cat(down(WC::Exceptions::NotFoundError))
          stub_open_library(error: down(OL::Exceptions::NotFoundError))
          stub_amazon_search([])
          sub = isbn_submission

          resolve(sub)

          assert_equal %w[empty empty empty], sub.reload.lookup.map { |entry| entry["outcome"] }
          assert sub.lookup.none? { |entry| entry.key?("error_class") }
        end

        test "lookup is replaced on each run and no other column is touched" do
          sub = isbn_submission(lookup: [{"source" => "old"}])
          stub_world_cat([wc_record])
          before = sub.reload.attributes.except("lookup")
          updated_at = sub.updated_at

          resolve(sub)

          assert_equal ["worldcat"], sub.reload.lookup.map { |entry| entry["source"] }
          assert_equal before, sub.attributes.except("lookup")
          assert_equal updated_at, sub.updated_at
        end

        test "title_authors records its answer" do
          sub = submission(:title_authors, typed_title: "A Quiet Year", typed_author_names: ["Anna Brenner"])

          resolve(sub)

          assert_equal [{"source" => "title_authors", "outcome" => "resolved", "title" => "A Quiet Year", "author_names" => ["Anna Brenner"]}], sub.reload.lookup
        end

        test "goodreads records its answer, and a missing page" do
          sub = submission(:goodreads, goodreads_book_id: 4010)

          resolve(sub)

          assert_equal [{"source" => "goodreads", "outcome" => "needs_page"}], sub.reload.lookup
        end
      end
    end
  end
end
