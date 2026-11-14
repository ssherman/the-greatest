# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsReimport
      class CorrectMatchTest < ActiveSupport::TestCase
        setup do
          @admin = users(:admin_user)
          @edition = ::Books::GoodreadsEdition.create!(goodreads_book_id: 91_001, signature: "cm-sig", title: "War and Peace", primary_author: "Leo Tolstoy")
          @ai_pick = books_books(:crime_and_punishment)
          @right = books_books(:war_and_peace)
        end

        def match_verdict(status: :proposed, outcome: "matched", book_id: @ai_pick.id, **attrs)
          payload = {"goodreads_edition_id" => @edition.id, "outcome" => outcome, "book_id" => book_id,
                     "ai" => {"answer" => book_id, "confidence" => "medium", "reason" => "looks alike"}}.merge(attrs.delete(:payload) || {})
          ::Books::RepairVerdict.create!(kind: :reimport_match, subject_key: "reimport:edition:#{@edition.id}", payload: payload,
            decided_by: :ai, confidence: :medium, status: status, **attrs)
        end

        def correct(verdict, **args) = CorrectMatch.call(verdict: verdict, user: @admin, **args)

        test "correcting to a book approves the match on that book and keeps the AI's pick on record" do
          verdict = match_verdict
          freeze_time do
            result = correct(verdict, book_id: @right.id)

            assert result.success?
            verdict.reload
            assert verdict.approved?
            assert_equal [@admin.id, Time.current], [verdict.decided_by_user_id, verdict.reviewed_at]
            assert_equal ["matched", @right.id], verdict.payload.values_at("outcome", "book_id")
            assert_equal({"outcome" => "matched", "book_id" => @ai_pick.id, "status" => "proposed", "by_user_id" => @admin.id,
                          "at" => Time.current.iso8601}, verdict.payload["corrected"])
            assert_equal({"answer" => @ai_pick.id, "confidence" => "medium", "reason" => "looks alike"}, verdict.payload["ai"])
            assert verdict.decided_by_ai?
          end
        end

        test "a rejected match can be corrected, which is how its waiting rows get moving again" do
          verdict = match_verdict(status: :rejected, reviewed_at: 1.day.ago)

          assert correct(verdict, book_id: @right.id).success?
          assert verdict.reload.approved?
          assert_equal "rejected", verdict.payload["corrected"]["status"]
        end

        test "correcting to create approves a new book for the edition" do
          verdict = match_verdict

          assert correct(verdict, create: true).success?
          verdict.reload
          assert verdict.approved?
          assert_equal "create", verdict.payload["outcome"]
          assert_nil verdict.payload["book_id"]
        end

        test "a create can be corrected to an existing book" do
          verdict = match_verdict(status: :approved, outcome: "create", book_id: nil)

          assert correct(verdict, book_id: @right.id).success?
          assert_equal ["matched", @right.id], verdict.reload.payload.values_at("outcome", "book_id")
          assert_equal "create", verdict.payload["corrected"]["outcome"]
        end

        test "a merged book's id resolves to the book it was merged into" do
          verdict = match_verdict
          GoodreadsReplay::Apply::MergedBook.stubs(:call).with(424_242).returns(@right)

          assert correct(verdict, book_id: 424_242).success?
          assert_equal @right.id, verdict.reload.payload["book_id"]
        end

        test "refuses, and changes nothing, when the match cannot be corrected" do
          cases = {
            "applied" => -> { match_verdict(applied_at: Time.current) },
            "book created" => -> { match_verdict(outcome: "create", book_id: nil, payload: {"created_book_id" => @right.id}) },
            "superseded" => -> { match_verdict(superseded_at: Time.current) },
            "apply started" => -> { match_verdict(status: :approved, payload: {"edition_before" => {"book_id" => nil}}) },
            "not a match" => -> { ::Books::RepairVerdict.create!(kind: :reimport_mixed, subject_key: "reimport:mixed:1", payload: {"book_id" => 1}, decided_by: :rule, status: :approved) }
          }
          cases.each do |label, build|
            ::Books::RepairVerdict.delete_all
            verdict = build.call
            before = verdict.attributes

            result = correct(verdict, book_id: @right.id)

            refute result.success?, label
            assert_equal before, verdict.reload.attributes, label
          end
        end

        test "refuses a missing book, and needs exactly one of a book or create" do
          verdict = match_verdict

          assert_match(/no book/i, correct(verdict, book_id: 999_999_999).errors.join)
          assert_match(/either/i, correct(verdict, book_id: @right.id, create: true).errors.join)
          assert_match(/either/i, correct(verdict).errors.join)
          assert verdict.reload.proposed?
        end

        test "apply then writes the corrected book as the edition's match" do
          verdict = match_verdict(status: :rejected)
          correct(verdict, book_id: @right.id)

          Apply::Match.call(verdict: verdict.reload)

          assert_equal [@right.id, "matched"], [@edition.reload.book_id, @edition.resolution]
        end
      end
    end
  end
end
