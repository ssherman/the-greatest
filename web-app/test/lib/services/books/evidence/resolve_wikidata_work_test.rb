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
          @client.stubs(:not_kept).returns(Set.new)
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
            "Q11" => entity("Q11", "War and Peace", instance_of: NOVEL, authors: ["Q7243"])
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

        test "a book by Unknown accepts a work whose only author is anonymous" do
          unknown_book_with_stored_qid
          @client.stubs(:entities).with(["Q_STORED"]).returns("Q_STORED" => entity("Q_STORED", "Mystery Tale", instance_of: NOVEL, authors: ["Q4233718"]))

          assert_equal "Q_STORED", call.data[:qid]
        end

        test "a book by Unknown accepts a work with no author" do
          unknown_book_with_stored_qid
          @client.stubs(:entities).with(["Q_STORED"]).returns("Q_STORED" => entity("Q_STORED", "Mystery Tale", instance_of: NOVEL))

          assert_equal "Q_STORED", call.data[:qid]
        end

        test "a book by Unknown rejects a work naming a real author" do
          unknown_book_with_stored_qid
          @client.stubs(:entities).with(["Q_STORED"]).returns("Q_STORED" => entity("Q_STORED", "Mystery Tale", instance_of: NOVEL, authors: ["Q42"]))

          data = call.data

          assert_nil data[:qid]
          assert_includes data[:rejected].map { it["reason"] }, "author_mismatch"
        end

        test "a book with a person author still rejects an anonymous work" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_wikidata_qid, value: "Q_STORED", source: :wikidata)
          @client.stubs(:entities).with(["Q_STORED"]).returns("Q_STORED" => entity("Q_STORED", "War and Peace", instance_of: NOVEL, authors: ["Q4233718"]))
          @client.stubs(:labels).returns({"Q4233718" => "anonymous"})

          assert_nil call.data[:qid]
        end

        test "an author known only by name passes when the label agrees" do
          Identifier.where(identifiable: books_authors(:tolstoy), identifier_type: :books_author_wikidata_qid).destroy_all
          Identifier.create!(identifiable: @book, identifier_type: :books_work_goodreads_id, value: "656")
          @client.stubs(:by_statements).returns(["Q161531"])
          @client.stubs(:entities).with(["Q161531"]).returns("Q161531" => entity("Q161531", "War and Peace", instance_of: NOVEL, authors: ["Q999"]))
          @client.stubs(:labels).with(["Q999"]).returns("Q999" => "Leo Tolstoy")

          assert_equal "Q161531", call.data[:qid]
        end

        test "an author with a QID is never matched by name" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_goodreads_id, value: "656")
          @client.stubs(:by_statements).returns(["Q161531"])
          @client.stubs(:entities).with(["Q161531"]).returns("Q161531" => entity("Q161531", "War and Peace", instance_of: NOVEL, authors: ["Q2"]))
          @client.expects(:labels).never

          data = call.data

          assert_nil data[:qid]
          assert_includes data[:rejected], {"id" => "Q161531", "reason" => "author_mismatch"}
        end

        test "a name match is allowed for the book's author that holds no QID" do
          @book.book_authors.create!(author: books_authors(:garnett))
          Identifier.create!(identifiable: @book, identifier_type: :books_work_goodreads_id, value: "656")
          @client.stubs(:by_statements).returns(["Q161531"])
          @client.stubs(:entities).with(["Q161531"]).returns("Q161531" => entity("Q161531", "War and Peace", instance_of: NOVEL, authors: ["Q9"]))
          @client.stubs(:labels).with(["Q9"]).returns("Q9" => "Constance Garnett")

          assert_equal "Q161531", call.data[:qid]
        end

        test "a pending pair raised by another source gains the QID, which then blocks both books" do
          other = conflict_setup(:wikidata)
          Services::DuplicateCandidates::Flag.call(item_type: "Books::Book", ids: [@book.id, other.id], source: :bulk_verify)

          call

          row = pair_candidates(other).sole
          assert_equal ["bulk_verify", ["Q161531"]], [row.source, row.evidence["wikidata_qids"]]
          assert_empty stored_values
          assert_empty Identifier.where(identifiable: other, identifier_type: :books_work_wikidata_qid)
          assert_equal @book.id, resolve_other(other)
          assert_empty Identifier.where(identifiable: other, identifier_type: :books_work_wikidata_qid)
        end

        test "a dismissed pair of any source gains the QID and blocks" do
          other = conflict_setup(:wikidata)
          Services::DuplicateCandidates::Flag.call(item_type: "Books::Book", ids: [@book.id, other.id], source: :ai)
          pair_candidates(other).update_all(status: DuplicateCandidate.statuses[:not_duplicate])

          call

          assert_equal ["Q161531"], pair_candidates(other).sole.evidence["wikidata_qids"]
          assert_equal @book.id, resolve_other(other)
          assert_empty stored_values
          assert_empty Identifier.where(identifiable: other, identifier_type: :books_work_wikidata_qid)
        end

        test "one pair colliding on two QIDs blocks both" do
          other = conflict_setup(:wikidata)
          call
          Identifier.create!(identifiable: other, identifier_type: :books_work_wikidata_qid, value: "Q2", source: :wikidata)
          @client.stubs(:by_statements).returns(["Q2"])
          @client.stubs(:entities).with(["Q2"]).returns("Q2" => entity("Q2", "War and Peace", instance_of: NOVEL, authors: ["Q7243"]))
          call

          assert_equal ["Q161531", "Q2"], pair_candidates(other).sole.evidence["wikidata_qids"]
          @client.stubs(:by_statements).returns(["Q161531"])
          assert_nil call.data[:qid]
          @client.stubs(:by_statements).returns(["Q2"])
          assert_nil call.data[:qid]
          assert_empty stored_values
        end

        test "a merged pair naming the QID in qids does not block" do
          other = conflict_setup(:wikidata)
          call
          pair_candidates(other).update_all(status: DuplicateCandidate.statuses[:merged])

          assert_equal "Q161531", call.data[:qid]
        end

        test "both books holding the QID with a wikidata source ends with neither holding it" do
          other = conflict_setup(:wikidata)
          Identifier.create!(identifiable: @book, identifier_type: :books_work_wikidata_qid, value: "Q161531", source: :wikidata)

          data = call.data

          assert_nil data[:qid]
          assert_equal other.id, data[:conflict_book_id]
          assert_empty stored_values
          assert_empty Identifier.where(identifiable: other, identifier_type: :books_work_wikidata_qid)
        end

        test "a stored QID is kept on conflict when it is not a wikidata-source row" do
          conflict_setup(:legacy)
          Identifier.create!(identifiable: @book, identifier_type: :books_work_wikidata_qid, value: "Q161531", source: :legacy)

          call

          assert_equal ["Q161531"], stored_values
        end

        test "a QID held by another book with a non-wikidata source stays with the holder and is flagged once" do
          other = conflict_setup(:legacy)

          2.times do
            data = call.data
            assert_nil data[:qid]
            assert_nil data[:work]
            assert_equal other.id, data[:conflict_book_id]
          end

          assert_empty stored_values
          assert_equal ["Q161531"], Identifier.where(identifiable: other, identifier_type: :books_work_wikidata_qid).pluck(:value)
          assert_equal 1, pair_candidates(other).count
        end

        test "a QID held by another book under a wikidata source ends up on neither" do
          other = conflict_setup(:wikidata)

          data = call.data

          assert_nil data[:qid]
          assert_equal other.id, data[:conflict_book_id]
          assert_empty stored_values
          assert_empty Identifier.where(identifiable: other, identifier_type: :books_work_wikidata_qid)
          assert_equal 1, pair_candidates(other).pending.count
        end

        test "the holder's later run does not re-store the QID while the candidate is pending" do
          other = conflict_setup(:wikidata)
          call
          Identifier.create!(identifiable: other, identifier_type: :books_work_goodreads_id, value: "999")
          other.update!(title: "War and Peace")
          other.book_authors.create!(author: books_authors(:tolstoy))

          data = ResolveWikidataWork.call(book: other, client: @client).data

          assert_nil data[:qid]
          assert_equal @book.id, data[:conflict_book_id]
          assert_empty Identifier.where(identifiable: other, identifier_type: :books_work_wikidata_qid)
        end

        test "a dismissed candidate still blocks the QID" do
          other = conflict_setup(:wikidata)
          call
          pair_candidates(other).update_all(status: DuplicateCandidate.statuses[:not_duplicate])

          data = call.data

          assert_nil data[:qid]
          assert_equal other.id, data[:conflict_book_id]
          assert_empty stored_values
        end

        test "a merged candidate does not block the QID" do
          other = conflict_setup(:wikidata)
          call
          pair_candidates(other).update_all(status: DuplicateCandidate.statuses[:merged])

          data = call.data

          assert_equal "Q161531", data[:qid]
          assert_equal ["Q161531"], stored_values
        end

        test "storing takes a per-QID advisory lock" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_goodreads_id, value: "656")
          @client.stubs(:by_statements).returns(["Q161531"])
          @client.stubs(:entities).with(["Q161531"]).returns("Q161531" => entity("Q161531", "War and Peace", instance_of: NOVEL, authors: ["Q7243"]))
          connection = Identifier.connection
          connection.stubs(:execute).with { |sql| !sql.include?("pg_advisory_xact_lock") }.returns(nil)
          connection.expects(:execute).with(regexp_matches(/pg_advisory_xact_lock\(hashtext\('Q161531'\)\)/)).once.returns(nil)

          assert_equal "Q161531", call.data[:qid]
        end

        test "a statement hit with a different title by the same author is rejected and not stored" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_goodreads_id, value: "656")
          @client.stubs(:by_statements).returns(["Q2"])
          @client.stubs(:entities).with(["Q2"]).returns("Q2" => entity("Q2", "Anna Karenina", instance_of: NOVEL, authors: ["Q7243"]))

          data = call.data

          assert_nil data[:qid]
          assert_includes data[:rejected], {"id" => "Q2", "reason" => "title_mismatch"}
          assert_empty stored_values
        end

        test "a stored QID whose label no longer matches is rejected and resolution falls through" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_wikidata_qid, value: "Q2", source: :legacy)
          @client.stubs(:entities).with(["Q2"]).returns("Q2" => entity("Q2", "Anna Karenina", instance_of: NOVEL, authors: ["Q7243"]))
          @client.stubs(:work_items).returns("Q7243" => [{"id" => "Q161531", "label" => "War and Peace"}])
          @client.stubs(:entities).with(["Q161531"]).returns("Q161531" => entity("Q161531", "War and Peace", instance_of: NOVEL, authors: ["Q7243"]))

          data = call.data

          assert_equal ["Q161531", "author_works"], [data[:qid], data[:via]]
          assert_includes data[:rejected], {"id" => "Q2", "reason" => "title_mismatch"}
        end

        test "a hit whose label matches an alternate title is accepted" do
          @book.update!(alternate_titles: ["Voyna i mir"])
          Identifier.create!(identifiable: @book, identifier_type: :books_work_goodreads_id, value: "656")
          @client.stubs(:by_statements).returns(["Q3"])
          @client.stubs(:entities).with(["Q3"]).returns("Q3" => entity("Q3", "Voyna i mir", instance_of: NOVEL, authors: ["Q7243"]))

          assert_equal "Q3", call.data[:qid]
        end

        test "a stored wikidata-source QID that is now a film is removed" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_wikidata_qid, value: "Q50", source: :wikidata)
          @client.stubs(:entities).with(["Q50"]).returns("Q50" => entity("Q50", "War and Peace", instance_of: FILM))

          data = call.data

          assert_nil data[:qid]
          assert_empty stored_values
        end

        test "a stored wikidata-source QID whose entity is missing is removed" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_wikidata_qid, value: "Q50", source: :wikidata)

          assert_nil call.data[:qid]
          assert_empty stored_values
        end

        test "a stored QID the service reports not kept is left in place and yields no evidence" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_wikidata_qid, value: "Q50", source: :wikidata)
          Identifier.create!(identifiable: @book, identifier_type: :books_work_goodreads_id, value: "656")
          @client.stubs(:not_kept).returns(Set["Q50"])
          @client.expects(:by_statements).never
          @client.expects(:work_items).never

          data = call.data

          assert_nil data[:qid]
          assert_nil data[:work]
          assert_equal ["Q50"], stored_values
          assert_includes data[:rejected], {"id" => "Q50", "reason" => "not_kept"}
        end

        test "a verified ISBN-13 keeps its slot when the other pairs fill the cap" do
          (1..60).each { |i| Identifier.create!(identifiable: @book, identifier_type: :books_work_goodreads_id, value: "g#{i}") }
          Identifier.create!(identifiable: @book, identifier_type: :books_work_isbn13, value: "9780385474542", source: :worldcat)
          @client.expects(:by_statements).with { |pairs, **| pairs.size == 50 && pairs.last == ["P212", "9780385474542"] }.returns([])

          call
        end

        test "a verified ISBN-13 is sent as a P212 statement and an edition hit resolves to its work" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_isbn13, value: "9780385474542", source: :worldcat)
          Identifier.create!(identifiable: @book, identifier_type: :books_work_isbn13, value: "9781400079988", source: :legacy)
          @client.expects(:by_statements).with([["P212", "9780385474542"]], limit: 50).returns(["Q900"])
          @client.stubs(:entities).with(["Q900"]).returns("Q900" => entity("Q900", "War and Peace", instance_of: EDITION, edition_of: ["Q161531"]))
          @client.stubs(:entities).with(["Q161531"]).returns("Q161531" => entity("Q161531", "War and Peace", instance_of: NOVEL, authors: ["Q7243"]))

          data = call.data

          assert_equal ["Q161531", "statements"], [data[:qid], data[:via]]
        end

        test "a stored legacy-source QID that is now a film is left in place" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_wikidata_qid, value: "Q50", source: :legacy)
          @client.stubs(:entities).with(["Q50"]).returns("Q50" => entity("Q50", "War and Peace", instance_of: FILM))

          assert_nil call.data[:qid]
          assert_equal ["Q50"], stored_values
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

        def conflict_setup(source)
          other = books_books(:crime_and_punishment)
          Identifier.create!(identifiable: other, identifier_type: :books_work_wikidata_qid, value: "Q161531", source: source)
          Identifier.create!(identifiable: @book, identifier_type: :books_work_goodreads_id, value: "656")
          @client.stubs(:by_statements).returns(["Q161531"])
          @client.stubs(:entities).with(["Q161531"]).returns("Q161531" => entity("Q161531", "War and Peace", instance_of: NOVEL, authors: ["Q7243"]))
          other
        end

        # Runs the other book through the resolver, which must find the same QID by its own Goodreads id.
        def resolve_other(other)
          Identifier.create!(identifiable: other, identifier_type: :books_work_goodreads_id, value: "999")
          other.update!(title: "War and Peace")
          other.book_authors.create!(author: books_authors(:tolstoy)) unless other.authors.include?(books_authors(:tolstoy))
          ResolveWikidataWork.call(book: other, client: @client).data[:conflict_book_id]
        end

        def pair_candidates(other)
          DuplicateCandidate.where(item_type: "Books::Book", item_a_id: [@book.id, other.id].min, item_b_id: [@book.id, other.id].max)
        end

        def call = ResolveWikidataWork.call(book: @book, client: @client)

        def unknown_book_with_stored_qid
          @book = ::Books::Book.create!(title: "Mystery Tale")
          @book.book_authors.create!(author: books_authors(:excluded_placeholder))
          Identifier.create!(identifiable: @book, identifier_type: :books_work_wikidata_qid, value: "Q_STORED", source: :wikidata)
        end

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
