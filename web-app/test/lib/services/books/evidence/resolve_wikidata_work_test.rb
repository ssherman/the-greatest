# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Evidence
      class ResolveWikidataWorkTest < ActiveSupport::TestCase
        NOVEL = "Q8261"
        FILM = "Q11424"
        EDITION = "Q3331189"

        setup do
          @book = books_books(:war_and_peace)
          @client = mock("wikidata client")
          @client.stubs(:by_statements).returns([])
          @client.stubs(:work_items).returns({})
          @client.stubs(:labels).returns({})
          @client.stubs(:entities).returns({})
          Identifier.create!(identifiable: books_authors(:tolstoy), identifier_type: :books_author_wikidata_qid, value: "Q7243")
        end

        test "a stored QID is used without asking for statements" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_wikidata_qid, value: "Q161531", source: :wikidata)
          @client.stubs(:entities).with(["Q161531"]).returns("Q161531" => entity("Q161531", "War and Peace", instance_of: NOVEL, authors: ["Q7243"]))
          @client.expects(:by_statements).never

          data = call.data

          assert_equal ["Q161531", "stored"], [data[:qid], data[:via]]
          assert_equal "Q161531", data[:work].id
        end

        test "a stored QID that answers under a new id is replaced by it" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_wikidata_qid, value: "Q1", source: :wikidata)
          @client.stubs(:entities).with(["Q1"]).returns("Q1" => entity("Q161531", "War and Peace", instance_of: NOVEL, authors: ["Q7243"]))

          data = call.data

          assert_equal ["Q161531", "stored"], [data[:qid], data[:via]]
          assert_equal ["Q161531"], stored_values
        end

        test "a Goodreads statement hit on a novel by our author is accepted and stored" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_goodreads_id, value: "656")
          @client.expects(:by_statements).with([["P2969", "656"]], limit: 50).returns(["Q161531"])
          @client.stubs(:entities).with(["Q161531"]).returns("Q161531" => entity("Q161531", "War and Peace", instance_of: NOVEL, authors: ["Q7243"]))

          data = call.data

          assert_equal ["Q161531", "statements"], [data[:qid], data[:via]]
          row = Identifier.find_by!(identifiable: @book, identifier_type: :books_work_wikidata_qid)
          assert_equal ["Q161531", "wikidata"], [row.value, row.source]
        end

        test "an edition hit with one P629 resolves to the work" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_oclc_id, value: "12345")
          @client.stubs(:by_statements).returns(["Q900"])
          @client.stubs(:entities).with(["Q900"]).returns("Q900" => entity("Q900", "War and Peace", instance_of: EDITION, edition_of: ["Q161531"]))
          @client.stubs(:entities).with(["Q161531"]).returns("Q161531" => entity("Q161531", "War and Peace", instance_of: NOVEL, authors: ["Q7243"]))

          assert_equal "Q161531", call.data[:qid]
        end

        test "an edition of several works is rejected as ambiguous" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_oclc_id, value: "12345")
          @client.stubs(:by_statements).returns(["Q900"])
          @client.stubs(:entities).with(["Q900"]).returns("Q900" => entity("Q900", "Omnibus", instance_of: EDITION, edition_of: ["Q1", "Q2"]))

          data = call.data

          assert_nil data[:qid]
          assert_includes data[:rejected], {"id" => "Q900", "reason" => "ambiguous_edition"}
        end

        test "a film hit is rejected as not a written work" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_goodreads_id, value: "656")
          @client.stubs(:by_statements).returns(["Q50"])
          @client.stubs(:entities).with(["Q50"]).returns("Q50" => entity("Q50", "War and Peace", instance_of: FILM))

          data = call.data

          assert_nil data[:qid]
          assert_nil data[:work]
          assert_includes data[:rejected], {"id" => "Q50", "reason" => "not_written_work"}
          assert_not Identifier.exists?(identifiable: @book, identifier_type: :books_work_wikidata_qid)
        end

        test "an author's work with the book's title is accepted via author works" do
          @client.stubs(:work_items).with(["Q7243"]).returns("Q7243" => [{"id" => "Q161531", "label" => "War and Peace"}, {"id" => "Q2", "label" => "Anna Karenina"}])
          @client.stubs(:entities).with(["Q161531"]).returns("Q161531" => entity("Q161531", "War and Peace", instance_of: NOVEL, authors: ["Q7243"]))

          data = call.data

          assert_equal ["Q161531", "author_works"], [data[:qid], data[:via]]
        end

        test "an alternate title also matches in author works" do
          @client.stubs(:work_items).returns("Q7243" => [{"id" => "Q3", "label" => "Voyna i mir"}])
          @client.stubs(:entities).with(["Q3"]).returns("Q3" => entity("Q3", "Voyna i mir", instance_of: NOVEL, authors: ["Q7243"]))

          assert_equal "Q3", call.data[:qid]
        end

        test "two distinct works with the same title store nothing" do
          @client.stubs(:work_items).returns("Q7243" => [{"id" => "Q10", "label" => "War and Peace"}, {"id" => "Q11", "label" => "War and Peace"}])
          @client.stubs(:entities).with(["Q10", "Q11"]).returns(
            "Q10" => entity("Q10", "War and Peace", instance_of: NOVEL, authors: ["Q7243"]),
            "Q11" => entity("Q11", "War and Peace", instance_of: NOVEL, authors: ["Q7243"])
          )

          data = call.data

          assert_nil data[:qid]
          assert_equal [["Q10", "ambiguous_title"], ["Q11", "ambiguous_title"]], data[:rejected].map { |r| [r["id"], r["reason"]] }
          assert_empty stored_values
        end

        test "ambiguous statements fall through to author works" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_goodreads_id, value: "656")
          @client.stubs(:by_statements).returns(["Q10", "Q11"])
          @client.stubs(:entities).with(["Q10", "Q11"]).returns(
            "Q10" => entity("Q10", "War and Peace", instance_of: NOVEL, authors: ["Q7243"]),
            "Q11" => entity("Q11", "Peace", instance_of: NOVEL, authors: ["Q7243"])
          )
          @client.stubs(:work_items).returns("Q7243" => [{"id" => "Q10", "label" => "War and Peace"}])
          @client.stubs(:entities).with(["Q10"]).returns("Q10" => entity("Q10", "War and Peace", instance_of: NOVEL, authors: ["Q7243"]))

          data = call.data

          assert_equal ["Q10", "author_works"], [data[:qid], data[:via]]
          assert_includes data[:rejected], {"id" => "Q10", "reason" => "ambiguous_statements"}
        end

        test "a book with no authors rejects a hit that lists authors" do
          book = books_books(:combo_steinbeck)
          assert_empty book.authors
          Identifier.create!(identifiable: book, identifier_type: :books_work_goodreads_id, value: "777")
          @client.stubs(:by_statements).returns(["Q20"])
          @client.stubs(:entities).with(["Q20"]).returns("Q20" => entity("Q20", "Of Mice and Men", instance_of: NOVEL, authors: ["Q39212"]))

          data = ResolveWikidataWork.call(book: book, client: @client).data

          assert_nil data[:qid]
          assert_includes data[:rejected], {"id" => "Q20", "reason" => "author_mismatch"}
        end

        test "an author known only by name passes when the label agrees" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_goodreads_id, value: "656")
          @client.stubs(:by_statements).returns(["Q161531"])
          @client.stubs(:entities).with(["Q161531"]).returns("Q161531" => entity("Q161531", "War and Peace", instance_of: NOVEL, authors: ["Q999"]))
          @client.stubs(:labels).with(["Q999"]).returns("Q999" => "Leo Tolstoy")

          assert_equal "Q161531", call.data[:qid]
        end

        test "a QID held by another book is stored on neither and flagged once" do
          other = books_books(:crime_and_punishment)
          Identifier.create!(identifiable: other, identifier_type: :books_work_wikidata_qid, value: "Q161531", source: :open_library)
          Identifier.create!(identifiable: @book, identifier_type: :books_work_goodreads_id, value: "656")
          @client.stubs(:by_statements).returns(["Q161531"])
          @client.stubs(:entities).with(["Q161531"]).returns("Q161531" => entity("Q161531", "War and Peace", instance_of: NOVEL, authors: ["Q7243"]))

          2.times do
            data = call.data
            assert_nil data[:qid]
            assert_nil data[:work]
            assert_equal other.id, data[:conflict_book_id]
          end

          assert_empty stored_values
          assert_equal ["Q161531"], Identifier.where(identifiable: other, identifier_type: :books_work_wikidata_qid).pluck(:value)
          candidates = DuplicateCandidate.where(item_type: "Books::Book", status: :pending, item_a_id: [@book.id, other.id].min, item_b_id: [@book.id, other.id].max)
          assert_equal 1, candidates.count
        end

        test "a stored QID that still resolves to itself is not rewritten" do
          row = Identifier.create!(identifiable: @book, identifier_type: :books_work_wikidata_qid, value: "Q161531", source: :open_library)
          @client.stubs(:entities).with(["Q161531"]).returns("Q161531" => entity("Q161531", "War and Peace", instance_of: NOVEL, authors: ["Q7243"]))

          call

          assert_equal ["open_library", row.updated_at], [row.reload.source, row.updated_at]
          assert_equal ["Q161531"], stored_values
        end

        test "every Goodreads id the book holds is sent, in id order" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_goodreads_id, value: "656")
          Identifier.create!(identifiable: @book, identifier_type: :books_work_goodreads_id, value: "657")
          @client.expects(:by_statements).with([["P2969", "656"], ["P2969", "657"]], limit: 50).returns([])

          call
        end

        test "Goodreads and OCLC ids go out in one call, Goodreads first" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_oclc_id, value: "12345")
          Identifier.create!(identifiable: @book, identifier_type: :books_work_goodreads_id, value: "656")
          @client.expects(:by_statements).once.with([["P2969", "656"], ["P243", "12345"]], limit: 50).returns([])

          call
        end

        test "statement pairs are capped" do
          60.times { |i| Identifier.create!(identifiable: @book, identifier_type: :books_work_goodreads_id, value: (1000 + i).to_s) }
          @client.expects(:by_statements).with { |pairs, **opts| pairs.size == 50 && opts == {limit: 50} }.returns([])

          call
        end

        test "an edition whose target is itself an edition is rejected" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_oclc_id, value: "12345")
          @client.stubs(:by_statements).returns(["Q900"])
          @client.stubs(:entities).with(["Q900"]).returns("Q900" => entity("Q900", "War and Peace", instance_of: EDITION, edition_of: ["Q901"]))
          @client.stubs(:entities).with(["Q901"]).returns("Q901" => entity("Q901", "War and Peace", instance_of: [EDITION, NOVEL], edition_of: ["Q161531"]))

          data = call.data

          assert_nil data[:qid]
          assert_includes data[:rejected], {"id" => "Q901", "reason" => "ambiguous_edition"}
        end

        test "an edition with no work is rejected as edition_without_work" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_oclc_id, value: "12345")
          @client.stubs(:by_statements).returns(["Q900"])
          @client.stubs(:entities).with(["Q900"]).returns("Q900" => entity("Q900", "War and Peace", instance_of: EDITION))

          data = call.data

          assert_nil data[:qid]
          assert_includes data[:rejected], {"id" => "Q900", "reason" => "edition_without_work"}
        end

        test "an entity that fails to distill is recorded as unparseable" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_oclc_id, value: "12345")
          @client.stubs(:by_statements).returns(["Q900"])
          @client.stubs(:entities).with(["Q900"]).returns("Q900" => {"id" => "Q900", "missing" => ""})

          data = call.data

          assert_nil data[:qid]
          assert_includes data[:rejected], {"id" => "Q900", "reason" => "unparseable"}
        end

        test "a full-limit statement answer may be cut off, so it is ambiguous and entities are not fetched" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_goodreads_id, value: "656")
          @client.stubs(:by_statements).returns((1..50).map { |i| "Q#{i}" })
          @client.expects(:entities).never

          data = call.data

          assert_nil data[:qid]
          assert_includes data[:rejected], {"id" => nil, "reason" => "ambiguous_statements"}
        end

        test "an edition whose work target fails to distill is recorded as unparseable" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_oclc_id, value: "12345")
          @client.stubs(:by_statements).returns(["Q900"])
          @client.stubs(:entities).with(["Q900"]).returns("Q900" => entity("Q900", "War and Peace", instance_of: EDITION, edition_of: ["Q901"]))
          @client.stubs(:entities).with(["Q901"]).returns("Q901" => {"id" => "Q901", "missing" => ""})

          data = call.data

          assert_nil data[:qid]
          assert_includes data[:rejected], {"id" => "Q901", "reason" => "unparseable"}
        end

        private

        def call = ResolveWikidataWork.call(book: @book, client: @client)

        def stored_values
          Identifier.where(identifiable: @book, identifier_type: :books_work_wikidata_qid).pluck(:value)
        end

        def entity(id, label, instance_of:, authors: [], edition_of: [])
          instance_of = Array(instance_of)
          {
            "id" => id,
            "labels" => {"en" => {"value" => label}},
            "claims" => {
              "P31" => claims(*instance_of),
              "P50" => claims(*authors),
              "P629" => claims(*edition_of)
            }
          }
        end

        def claims(*ids)
          ids.map { |id| {"rank" => "normal", "mainsnak" => {"snaktype" => "value", "datavalue" => {"value" => {"id" => id}}}} }
        end
      end
    end
  end
end
