# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsReimport
      class DecideRowTest < ActiveSupport::TestCase
        setup do
          @user = users(:regular_user)
          @war = books_books(:war_and_peace)
          @crime = books_books(:crime_and_punishment)
          @n = 0
          @row_number = 9_000
          @import = replay_import(@user)
          ::Services::Books::GoodreadsRebuild::Cohort.stubs(:trusted?).returns(false)
        end

        def replay_import(user, finished_at: Time.current)
          ::Books::GoodreadsImport.create!(user: user, source: :legacy_replay, status: :complete, finished_at: finished_at)
        end

        def edition
          @n += 1
          ::Books::GoodreadsEdition.create!(goodreads_book_id: 95_000 + @n, signature: "dr-sig-#{@n}", title: "T#{@n}", primary_author: "A")
        end

        def row(edition, legacy: nil, import: @import, rating: nil, review: nil)
          ::Books::GoodreadsImportRow.create!(import: import, row_number: (@row_number += 1), raw: {"Title" => "T"},
            goodreads_edition: edition, legacy_book_id: legacy&.id, rating: rating, review_body: review)
        end

        def match(edition, book, applied: true, status: :approved, created: false)
          payload = {"outcome" => created ? "create" : "matched", "goodreads_edition_id" => edition.id}
          payload[created ? "created_book_id" : "book_id"] = book.id
          ::Books::RepairVerdict.create!(kind: :reimport_match, subject_key: "reimport:edition:#{edition.id}", decided_by: :ai,
            status: status, payload: payload, applied_at: applied ? Time.current : nil)
        end

        def decide(row) = DecideRow.call(row: row)

        def payload_for_decision(row) = decide(row)

        def payload_for(row)
          ::Books::RepairVerdict.find_by!(kind: :reimport_row, subject_key: "reimport:row:#{row.import_id}:#{row.row_number}")
        end

        test "waits, recording nothing, when the match is unapplied, unapproved, rejected or missing" do
          e1, e2, e3, e4 = edition, edition, edition, edition
          match(e1, @war, applied: false)
          match(e2, @war, status: :proposed)
          match(e3, @war, status: :rejected)
          rows = [e1, e2, e3, e4].map { |e| row(e, legacy: @crime) }

          rows.each { |r| assert_equal :waiting, decide(r).data[:outcome] }
          assert_equal 0, ::Books::RepairVerdict.where(kind: :reimport_row).count
        end

        test "a created book is the destination once the create applied" do
          e = edition
          match(e, @war, created: true)
          r = row(e, legacy: @crime)

          assert_equal :recorded, decide(r).data[:outcome]
          assert_equal @war.id, payload_for(r).payload["to_book_id"]
        end

        test "no legacy book is an add, with the exact payload keys" do
          e = edition
          match(e, @war)
          verdict = decide(row(e)).data[:verdict]

          assert_equal "add", verdict.payload["action"]
          assert verdict.approved?
          assert verdict.decided_by_rule?
          assert_equal %w[action from_book_id goodreads_edition_id import_id review row_number superseded_by to_book_id user_id],
            verdict.payload.keys.sort
          assert_nil verdict.payload["from_book_id"]
          assert_nil verdict.payload["superseded_by"]
        end

        test "a legacy book equal to the destination is a keep" do
          e = edition
          match(e, @war)
          p = decide(row(e, legacy: @war)).data[:verdict].payload

          assert_equal ["keep", @war.id, @war.id], p.values_at("action", "from_book_id", "to_book_id")
        end

        test "a different legacy book is a move" do
          e = edition
          match(e, @war)
          verdict = decide(row(e, legacy: @crime)).data[:verdict]

          assert_equal ["move", @crime.id, @war.id], verdict.payload.values_at("action", "from_book_id", "to_book_id")
          assert verdict.approved?
        end

        test "a legacy book that was merged away is followed" do
          e = edition
          match(e, @war)
          ::Services::Books::GoodreadsReplay::Apply::MergedBook.stubs(:call).with(@war.id).returns(@war)
          ::Services::Books::GoodreadsReplay::Apply::MergedBook.stubs(:call).with(555).returns(@crime)
          r = row(e)
          r.update!(legacy_book_id: 555)

          assert_equal @crime.id, decide(r).data[:verdict].payload["from_book_id"]
        end

        test "the destination follows a match book that was merged away" do
          e = edition
          match(e, @war)
          ::Services::Books::GoodreadsReplay::Apply::MergedBook.stubs(:call).with(@war.id).returns(@crime)
          ::Services::Books::GoodreadsReplay::Apply::MergedBook.stubs(:call).with(@crime.id).returns(@crime)

          assert_equal @crime.id, decide(row(e, legacy: @crime)).data[:verdict].payload["to_book_id"]
          assert_equal "keep", ::Books::RepairVerdict.reimport_row.last.payload["action"]
        end

        test "a move off a trusted book is proposed, a keep on one is not" do
          ::Services::Books::GoodreadsRebuild::Cohort.stubs(:trusted?).with(@crime.id).returns(true)
          e1, e2 = edition, edition
          match(e1, @war)
          match(e2, @crime)

          assert decide(row(e1, legacy: @crime)).data[:verdict].proposed?
          other = replay_import(users(:admin_user))
          assert decide(row(e2, legacy: @crime, import: other)).data[:verdict].approved?
        end

        test "Review Focus 1: two editions legacy put on one book are copied, each reviewed from its own row" do
          e1, e2 = edition, edition
          match(e1, @war)
          match(e2, @crime)
          r1 = row(e1, legacy: @war, rating: 4, review: "great")
          r2 = row(e2, legacy: @war, rating: 3)

          v1 = decide(r1).data[:verdict].payload
          v2 = decide(r2).data[:verdict].payload

          assert_equal %w[copy copy], [v1["action"], v2["action"]]
          assert_equal [@war.id, @crime.id], [v1["to_book_id"], v2["to_book_id"]]
          assert_equal [true, false], [v1["review"], v2["review"]]
        end

        test "a copy group's review goes to the row that has something" do
          e1, e2 = edition, edition
          match(e1, @war)
          match(e2, @crime)
          r1 = row(e1, legacy: @war, rating: 4)
          r2 = row(e2, legacy: @war)

          assert_equal [true, false], [decide(r1).data[:verdict].payload["review"], decide(r2).data[:verdict].payload["review"]]
        end

        test "a from-book group with nothing to carry gives the review flag to its newest row" do
          e1, e2 = edition, edition
          match(e1, @war)
          match(e2, @crime)
          newer = replay_import(@user, finished_at: 1.day.from_now)
          r1 = row(e1, legacy: @war)
          r2 = row(e2, legacy: @war, import: newer)

          assert_equal [false, true], [decide(r1).data[:verdict].payload["review"], decide(r2).data[:verdict].payload["review"]]
        end

        test "a copy group waits until every sibling row has a destination" do
          e1, e2 = edition, edition
          match(e1, @war)
          r1 = row(e1, legacy: @crime)
          row(e2, legacy: @crime)

          assert_equal :waiting, decide(r1).data[:outcome]
        end

        test "every row of a user waits while any live row lacks a destination, a rejected edition excepted" do
          e1, e2, e3 = edition, edition, edition
          match(e1, @war)
          match(e3, @war, status: :rejected)
          r1 = row(e1, legacy: @crime)
          r2 = row(e2)
          r3 = row(e3)

          assert_equal %i[waiting waiting waiting], [r1, r2, r3].map { |r| decide(r).data[:outcome] }
          assert_equal 0, ::Books::RepairVerdict.where(kind: :reimport_row).count

          match(e2, @war)
          assert_equal :recorded, decide(r1).data[:outcome]
          assert_equal :waiting, decide(r3).data[:outcome]
        end

        test "a group with a rejected sibling waits as a whole, recording nothing" do
          e1, e2 = edition, edition
          match(e1, @war)
          match(e2, @crime, status: :rejected)
          r1 = row(e1, legacy: @war)
          r2 = row(e2, legacy: @war, rating: 5, review: "about the other book")

          assert_equal %i[waiting waiting], [r1, r2].map { |r| decide(r).data[:outcome] }
          assert_equal 0, ::Books::RepairVerdict.where(kind: :reimport_row).count
        end

        test "a group with a row that has no edition waits as a whole, and other groups go on" do
          e1, e2 = edition, edition
          match(e1, @crime)
          match(e2, @war)
          r1 = row(e1, legacy: @war)
          ::Books::GoodreadsImportRow.create!(import: @import, row_number: (@row_number += 1), raw: {"Title" => "T"}, legacy_book_id: @war.id)
          other = row(e2, legacy: @crime)

          assert_equal [:waiting, :recorded], [decide(r1).data[:outcome], decide(other).data[:outcome]]
          assert_equal ["reimport:row:#{@import.id}:#{other.row_number}"], ::Books::RepairVerdict.where(kind: :reimport_row).pluck(:subject_key)
        end

        test "siblings are grouped by the merged legacy book" do
          e1, e2 = edition, edition
          match(e1, @war)
          match(e2, @crime)
          ::Services::Books::GoodreadsReplay::Apply::MergedBook.stubs(:call).with(@war.id).returns(@war)
          ::Services::Books::GoodreadsReplay::Apply::MergedBook.stubs(:call).with(@crime.id).returns(@crime)
          ::Services::Books::GoodreadsReplay::Apply::MergedBook.stubs(:call).with(701).returns(@war)
          ::Services::Books::GoodreadsReplay::Apply::MergedBook.stubs(:call).with(702).returns(@war)
          r1 = row(e1)
          r1.update!(legacy_book_id: 701)
          r2 = row(e2)
          r2.update!(legacy_book_id: 702)

          assert_equal %w[copy copy], [decide(r1).data[:verdict].payload["action"], decide(r2).data[:verdict].payload["action"]]
        end

        test "applied verdicts are final: an unchanged decision is kept" do
          e = edition
          match(e, @war)
          r = row(e, legacy: @crime)
          payload_for_decision(r)
          payload_for(r).update!(applied_at: Time.current)

          assert_equal :kept, decide(r).data[:outcome]
        end

        test "applied verdicts are final: a review flag that would flip is a conflict" do
          e = edition
          match(e, @war)
          r = row(e, legacy: @crime)
          payload_for_decision(r)
          verdict = payload_for(r)
          verdict.update!(applied_at: Time.current, payload: verdict.payload.merge("review" => false))
          before = verdict.reload.payload

          assert_equal :conflict, decide(r).data[:outcome]
          assert_equal before, verdict.reload.payload
        end

        test "a verdict that recorded its trail but lost applied_at is final too, and its trail survives" do
          e = edition
          match(e, @war)
          r = row(e, legacy: @crime)
          payload_for_decision(r)
          verdict = payload_for(r)
          verdict.update!(payload: verdict.payload.merge("review" => false, "moved" => {"list_item_ids_before" => [1]}))
          before = verdict.reload.payload

          assert_equal :conflict, decide(r).data[:outcome]
          assert_equal before, verdict.reload.payload
        end

        test "a created book counts as the destination as soon as it is stored, applied_at or not" do
          e = edition
          match(e, @war, created: true, applied: false)
          r = row(e, legacy: @crime)

          assert_equal :recorded, decide(r).data[:outcome]
        end

        test "applied verdicts are final: a move that would become a copy is a conflict" do
          e1, e2 = edition, edition
          match(e1, @war)
          r1 = row(e1, legacy: @crime)
          payload_for_decision(r1)
          payload_for(r1).update!(applied_at: Time.current)
          before = payload_for(r1).payload
          match(e2, @crime)
          row(e2, legacy: @crime)

          assert_equal :conflict, decide(r1).data[:outcome]
          assert_equal before, payload_for(r1).payload
        end

        test "applied verdicts are final: a newer import appearing after a move applied is a conflict" do
          e = edition
          match(e, @war)
          r = row(e, legacy: @crime)
          payload_for_decision(r)
          payload_for(r).update!(applied_at: Time.current)
          before = payload_for(r).payload
          row(e, legacy: @crime, import: replay_import(@user, finished_at: 1.day.from_now))

          assert_equal :conflict, decide(r).data[:outcome]
          assert_equal before, payload_for(r).payload
        end

        test "a changed applied row makes its whole legacy-book group a conflict, siblings record nothing" do
          third = books_books(:got)
          e1, e2 = edition, edition
          match(e1, @war)
          r1 = row(e1, legacy: @crime, rating: 4, review: "x")
          decide(r1)
          verdict = payload_for(r1)
          assert_equal true, verdict.payload["review"]
          verdict.update!(applied_at: Time.current)
          before = verdict.reload.payload
          match(e2, third)
          r2 = row(e2, legacy: @crime, rating: 3, import: replay_import(@user, finished_at: 1.day.from_now))

          assert_equal :conflict, decide(r1).data[:outcome]
          assert_equal :conflict, decide(r2).data[:outcome]
          assert_nil ::Books::RepairVerdict.find_by(subject_key: "reimport:row:#{r2.import_id}:#{r2.row_number}")
          assert_equal before, verdict.reload.payload
        end

        test "an unchanged applied row still lets its sibling be recorded" do
          e1, e2 = edition, edition
          match(e1, @war)
          match(e2, @war)
          r1 = row(e1, legacy: @crime, rating: 4)
          r2 = row(e2, legacy: @crime)
          decide(r1)
          payload_for(r1).update!(applied_at: Time.current)

          assert_equal :kept, decide(r1).data[:outcome]
          assert_equal :recorded, decide(r2).data[:outcome]
        end

        test "two rows from one legacy book going to the same destination stay moves" do
          e1, e2 = edition, edition
          match(e1, @war)
          match(e2, @war)

          assert_equal "move", decide(row(e1, legacy: @crime)).data[:verdict].payload["action"]
          assert_equal "move", decide(row(e2, legacy: @crime)).data[:verdict].payload["action"]
        end

        test "Review Focus 2: the same edition in a newer completed import supersedes the older row" do
          e = edition
          match(e, @war)
          newer_import = replay_import(@user, finished_at: 1.day.from_now)
          old = row(e, legacy: @crime, rating: 5)
          new = row(e, legacy: @crime, import: newer_import, rating: 2)

          old_verdict = decide(old).data[:verdict]
          assert_nil old_verdict.payload["from_book_id"]
          assert_equal "keep", old_verdict.payload["action"]
          assert_equal "reimport:row:#{newer_import.id}:#{new.row_number}", old_verdict.payload["superseded_by"]
          assert_equal false, old_verdict.payload["review"]
          assert old_verdict.approved?

          new_payload = decide(new).data[:verdict].payload
          assert_equal "move", new_payload["action"]
          assert_nil new_payload["superseded_by"]
          assert_equal true, new_payload["review"]
        end

        test "another user's import of the same edition supersedes nothing" do
          e = edition
          match(e, @war)
          other = replay_import(users(:admin_user), finished_at: 1.day.from_now)
          mine = row(e, legacy: @crime)
          row(e, legacy: @crime, import: other)

          assert_equal "move", decide(mine).data[:verdict].payload["action"]
        end

        test "an incomplete or member import does not supersede" do
          e = edition
          match(e, @war)
          mine = row(e, legacy: @crime)
          row(e, import: ::Books::GoodreadsImport.create!(user: @user, source: :legacy_replay, status: :writing, finished_at: 1.day.from_now))
          row(e, import: ::Books::GoodreadsImport.create!(user: @user, source: :member, status: :complete, finished_at: 1.day.from_now))

          assert_nil decide(mine).data[:verdict].payload["superseded_by"]
        end

        test "adds: one row per destination writes the review, the newest one that has something" do
          e1, e2, e3 = edition, edition, edition
          [e1, e2, e3].each { |e| match(e, @war) }
          newer_import = replay_import(@user, finished_at: 1.day.from_now)
          older = row(e1, rating: 5)
          newer = row(e2, review: "text", import: newer_import)
          unrated = row(e3, import: newer_import)

          assert_equal [false, true, false], [older, newer, unrated].map { |r| decide(r).data[:verdict].payload["review"] }
        end

        test "a zero rating without review text carries no review" do
          e = edition
          match(e, @war)

          assert_equal false, decide(row(e, rating: 0)).data[:verdict].payload["review"]
        end

        test "deciding twice records one verdict and leaves an admin-reviewed one alone" do
          e = edition
          match(e, @war)
          r = row(e, legacy: @crime)
          decide(r)

          assert_equal :recorded, decide(r).data[:outcome]
          assert_equal 1, ::Books::RepairVerdict.where(kind: :reimport_row).count

          payload_for(r).update!(reviewed_at: Time.current)
          assert_equal :kept, decide(r).data[:outcome]
        end
      end
    end
  end
end
