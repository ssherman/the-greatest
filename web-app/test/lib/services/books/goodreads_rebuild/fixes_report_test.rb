# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsRebuild
      class FixesReportTest < ActiveSupport::TestCase
        setup do
          @source = ::Books::Book.create!(title: "Wrong Title")
          @target = ::Books::Book.create!(title: "Tenth of December")
          @fixed = ::Books::Book.create!(title: "Muddled")
          @fixed.book_authors.create!(author: ::Books::Author.create!(name: "Someone Else"), position: 1)
        end

        def verdict(kind, key, payload, status: :approved, confidence: :high, applied_at: nil, error: nil)
          ::Books::RepairVerdict.create!(kind: kind, subject_key: key, payload: payload, status: status, confidence: confidence,
            decided_by: :rule, applied_at: applied_at, error: error)
        end

        test "counts verdicts by kind, status and confidence and shows the export title beside ours" do
          verdict(:merge_books, "rebuild:#{@source.id}", {"source_id" => @source.id, "target_id" => @target.id,
                                                          "full_title" => "Tenth of December: Stories"}, confidence: :certain)
          verdict(:fix_identity, "rebuild:#{@fixed.id}", {"book_id" => @fixed.id, "full_title" => "The Real Title",
                                                          "author_names" => ["George Saunders"]}, status: :proposed, confidence: :medium,
            applied_at: Time.current)
          verdict(:fix_identity, "rebuild:999999999", {"book_id" => 999_999_999}, error: "boom: it broke")
          verdict(:relink, "other:1", {})

          report = FixesReport.call

          assert_includes report, "merge_books approved certain 1"
          assert_includes report, "fix_identity proposed medium 1"
          assert_includes report, "fix_identity approved high 1"
          refute_includes report, "relink"
          assert_includes report, %(book ##{@source.id} "Wrong Title" -> ##{@target.id} "Tenth of December" | export: "Tenth of December: Stories")
          assert_includes report, %(##{@fixed.id} "Muddled" by Someone Else -> "The Real Title" by George Saunders)
          assert_match(/applied: 1/, report)
          assert_match(/with an error: 1/, report)
          assert_includes report, "boom: it broke"
        end

        test "reports enrichment runs, Goodreads outcomes, the gate's daily count and a block" do
          stub_workflow_dispatch
          ::Books::Goodreads::FetchGate.any_instance.stubs(:usage)
            .returns(::Books::Goodreads::FetchGate::Usage.new(day: Time.current.utc.to_date, count: 812))
          ::Books::Goodreads::FetchGate.any_instance.stubs(:blocked_until).returns(Time.utc(2026, 10, 29, 18, 30))
          Rails.application.config.x.goodreads.stubs(:daily_fetch_cap).returns(1_500)
          run = ->(status, outcome, state, created_at = Time.current) do
            book = ::Books::Book.create!(title: "Enriched #{outcome}#{status}")
            WorkflowRun.create!(workflow: "books.book_enrichment", definition_version: 2, enrichable: book, status: status,
              initiated_by: "goodreads_rebuild", options: {}, created_at: created_at).tap do |r|
              r.steps.create!(key: "goodreads", queue: "goodreads_fetch", lease_seconds: 600, state: state, outcome: outcome, finished_at: created_at)
            end
          end
          run.call(:completed, "matched", :succeeded)
          run.call(:completed, "no_match", :succeeded, 2.days.ago)
          run.call(:completed_with_failures, nil, :failed)
          run.call(:running, nil, :waiting)

          report = FixesReport.call

          assert_includes report, "runs started: 4, finished: 3, failed: 1"
          assert_includes report, "Goodreads pages found: 1 (today 1), missed: 1 (today 0), failed: 1 (today 1)"
          assert_includes report, "Goodreads fetches today: 812 of 1,500"
          assert_includes report, "blocked until 2026-10-29 18:30 UTC"
        end

        test "says plainly when the line has run into tomorrow's fetches, and when nothing is stored" do
          Rails.application.config.x.goodreads.stubs(:daily_fetch_cap).returns(1_500)
          usage = ::Books::Goodreads::FetchGate::Usage
          today = Time.current.utc.to_date
          ::Books::Goodreads::FetchGate.any_instance.stubs(:blocked_until).returns(nil)
          ::Books::Goodreads::FetchGate.any_instance.stubs(:usage).returns(usage.new(day: today + 1, count: 37))

          assert_includes FixesReport.call, "Goodreads fetches today: all 1,500 used; 37 of tomorrow's already reserved (gate not blocked)"

          ::Books::Goodreads::FetchGate.any_instance.stubs(:usage).returns(usage.new(day: today - 1, count: 900))

          assert_includes FixesReport.call, "Goodreads fetches today: 0 of 1,500 (gate not blocked)"
        end
      end
    end
  end
end
