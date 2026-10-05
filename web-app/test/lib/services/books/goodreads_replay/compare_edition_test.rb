require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      class CompareEditionTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        setup do
          @user = users(:regular_user)
          @legacy = books_books(:war_and_peace)       # legacy's choice
          @resolved = books_books(:crime_and_punishment) # the resolver's answer
          @edition = goodreads_edition(title: "War and Peace", primary_author: "Leo Tolstoy", isbn13: "9780140447934")
          ::Identifier.create!(identifiable: @legacy, identifier_type: :books_work_goodreads_id, value: @edition.goodreads_book_id.to_s)
          UserListItem.create!(user_list: user_lists(:regular_user_books_read), listable: @legacy)
          @import = replay_import(legacy_import_id: 501)
          @row = @import.rows.create!(row_number: 3, goodreads_edition: @edition)
          @finder = ::DataImporters::Books::Book::Finder.new
          @query = ::Services::Books::GoodreadsImports::EditionQuery.call(@edition)
        end

        def replay_import(legacy_import_id:, user: @user)
          ::Books::GoodreadsImport.create!(user: user, source: :legacy_replay, status: :complete, legacy_import_id: legacy_import_id)
        end

        def match(record, decided_by: :ai, confidence: :high)
          decision = ::MatchDecision.create!(finder: "DataImporters::Books::Book::Finder", subject: @edition, record: record,
            outcome: record ? :matched : :unmatched, confidence: confidence, decided_by: decided_by, ai_chat: ai_chats(:general_chat))
          ::DataImporters::Match.new(outcome: record ? :matched : :unmatched, record: record, confidence: confidence,
            decided_by: decided_by, reason: "test reason", candidates: [], decision: decision, sources_failed: [])
        end

        def compare(match, final: true, query: @query)
          CompareEdition.call(edition: @edition, match: match, finder: @finder, query: query, final: final)
        end

        def contradicting_query
          ::DataImporters::Books::Book::ImportQuery.new(title: "Some Other Novel", author_names: ["Nobody Known"])
        end

        test "the resolver choosing legacy's book is agreement, with no verdict" do
          result = compare(match(@legacy))

          assert_predicate @row.reload, :replay_agrees?
          assert_equal @legacy.id, @row.legacy_book_id
          assert_equal({agrees: 1}, result.data[:tally])
          assert_equal 0, ::Books::RepairVerdict.count
        end

        test "a row with no legacy choice is counted as such" do
          UserListItem.where(listable: @legacy).delete_all

          compare(match(@resolved))

          assert_predicate @row.reload, :replay_no_legacy_choice?
          assert_nil @row.legacy_book_id
        end

        test "pass one leaves a disagreement for the full pass and records nothing" do
          result = compare(match(@resolved), final: false)

          assert result.data[:needs_full_pass]
          assert_predicate @row.reload, :replay_awaiting_full_pass?
          assert_equal 0, ::Books::RepairVerdict.count
        end

        test "an AI disagreement on the final pass is a proposed relink for that user" do
          decision_match = match(@resolved)
          compare(decision_match)

          verdict = ::Books::RepairVerdict.relink.sole
          assert_predicate @row.reload, :replay_disagrees?
          assert_equal "user:#{@user.id}:book:#{@legacy.id}:goodreads:#{@edition.goodreads_book_id}", verdict.subject_key
          assert_predicate verdict, :proposed?
          assert_predicate verdict, :decided_by_ai?
          assert_equal ai_chats(:general_chat).id, verdict.ai_chat_id
          assert_equal({"user_id" => @user.id, "from_book_id" => @legacy.id, "to_book_id" => @resolved.id,
                        "goodreads_book_id" => @edition.goodreads_book_id, "rows" => [[501, 3]],
                        "match_decision_id" => decision_match.decision.id, "strip_identifiers" => [],
                        "stamp_identifiers" => [],
                        "row" => {"title" => "War and Peace", "author" => "Leo Tolstoy"}}, verdict.payload)
        end

        test "a rule-certain disagreement is approved on its own" do
          compare(match(@resolved, decided_by: :rule, confidence: :high))

          verdict = ::Books::RepairVerdict.relink.sole
          assert_predicate verdict, :approved?
          assert_predicate verdict, :decided_by_rule?
        end

        test "when legacy's book contradicts the row's title and author, the relink also moves the row's identifiers" do
          ::Identifier.create!(identifiable: @legacy, identifier_type: :books_work_isbn13, value: "9780140447934") unless
            @legacy.identifiers.exists?(identifier_type: :books_work_isbn13, value: "9780140447934")

          compare(match(@resolved), query: contradicting_query)

          assert_equal [["books_work_goodreads_id", @edition.goodreads_book_id.to_s], ["books_work_isbn13", "9780140447934"]],
            ::Books::RepairVerdict.relink.sole.payload["strip_identifiers"]
        end

        test "a slug-form id on legacy's book is stripped in every form and stamped on the right book bare" do
          id = @edition.goodreads_book_id.to_s
          ::Identifier.where(identifiable: @legacy, identifier_type: :books_work_goodreads_id).update_all(value: "#{id}-war-and-peace")

          compare(match(@resolved), query: contradicting_query)

          payload = ::Books::RepairVerdict.relink.sole.payload
          assert_equal [["books_work_goodreads_id", id], ["books_work_goodreads_id", "#{id}-war-and-peace"], ["books_work_isbn13", "9780140447934"]],
            payload["strip_identifiers"]
          assert_equal [["books_work_goodreads_id", id], ["books_work_isbn13", "9780140447934"]], payload["stamp_identifiers"]
        end

        test "legacy's book and the resolver's already being a duplicate pair is a duplicate finding, not a relink" do
          ::Services::DuplicateCandidates::Flag.call(item_type: "Books::Book", ids: [@legacy.id, @resolved.id], source: :ai)

          compare(match(@resolved))

          assert_predicate @row.reload, :replay_duplicate?
          assert_equal 0, ::Books::RepairVerdict.count
        end

        test "unmatched with a contradicting legacy book proposes stripping its identifiers, with cached page facts" do
          goodreads_page(goodreads_book_id: @edition.goodreads_book_id, title: "War and Peace", authors: [["Leo Tolstoy", "Author"]])

          compare(match(nil), query: contradicting_query)

          verdict = ::Books::RepairVerdict.strip_identifier.sole
          assert_predicate @row.reload, :replay_unmatched?
          assert_equal "book:#{@legacy.id}:books_work_goodreads_id:#{@edition.goodreads_book_id}", verdict.subject_key
          assert_predicate verdict, :proposed?
          assert_equal [["books_work_goodreads_id", @edition.goodreads_book_id.to_s], ["books_work_isbn13", "9780140447934"]],
            verdict.payload["remove"]
          assert_equal [], verdict.payload["add"]
          assert_equal({"outcome" => "found", "title" => "War and Peace", "authors" => ["Leo Tolstoy"]}, verdict.payload["goodreads_page"])
        end

        test "unmatched where legacy's book still agrees on title or author is counted, not queued" do
          compare(match(nil))

          assert_predicate @row.reload, :replay_unmatched?
          assert_equal 0, ::Books::RepairVerdict.count
        end

        test "one user's two imports naming the edition give one relink, and both imports' rows are compared" do
          second = replay_import(legacy_import_id: 502)
          second_row = second.rows.create!(row_number: 9, goodreads_edition: @edition)

          compare(match(@resolved))

          verdict = ::Books::RepairVerdict.relink.sole
          assert_equal [[501, 3], [502, 9]], verdict.payload["rows"].sort
          assert_predicate second_row.reload, :replay_disagrees?
        end

        test "member imports' rows are not the replay's" do
          member = ::Books::GoodreadsImport.create!(user: users(:editor_user), source: :member, status: :complete)
          member_row = member.rows.create!(row_number: 1, goodreads_edition: @edition)

          compare(match(@resolved))

          assert_nil member_row.reload.replay_finding
        end
      end
    end
  end
end
