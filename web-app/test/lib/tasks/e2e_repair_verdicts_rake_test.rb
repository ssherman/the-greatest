# frozen_string_literal: true

require "test_helper"
require "rake"

class E2eRepairVerdictsRakeTest < ActiveSupport::TestCase
  setup do
    unless Rake::Task.task_defined?("e2e:repair_verdicts_seed")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/e2e.rake").to_s }
    end
    Rake::Task["e2e:repair_verdicts_seed"].reenable
    Rake::Task["e2e:repair_verdicts_cleanup"].reenable
  end

  test "seeds a proposed relink and a proposed re-import match, idempotently, and cleans them up" do
    ENV["E2E_BOOK_A"] = books_books(:war_and_peace).slug
    ENV["E2E_BOOK_B"] = books_books(:got).slug
    out, = capture_io { Rake::Task["e2e:repair_verdicts_seed"].invoke }
    Rake::Task["e2e:repair_verdicts_seed"].reenable
    capture_io { Rake::Task["e2e:repair_verdicts_seed"].invoke }

    ids = JSON.parse(out.lines.last)
    verdict = ::Books::RepairVerdict.find(ids["verdict_id"])
    assert_predicate verdict, :proposed?
    match = ::Books::RepairVerdict.find(ids["match_verdict_id"])
    assert_predicate match, :reimport_match?
    assert_predicate match, :proposed?
    # No edition with this id, so an apply run passes the match by without touching anything.
    refute ::Books::GoodreadsEdition.exists?(match.payload["goodreads_edition_id"])
    assert_equal 2, ::Books::RepairVerdict.where("subject_key LIKE 'e2e:%'").count

    capture_io { Rake::Task["e2e:repair_verdicts_cleanup"].invoke }
    assert_equal 0, ::Books::RepairVerdict.where("subject_key LIKE 'e2e:%'").count
  ensure
    ENV.delete("E2E_BOOK_A")
    ENV.delete("E2E_BOOK_B")
  end
end
