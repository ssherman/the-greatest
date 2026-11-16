# frozen_string_literal: true

require "test_helper"
require "rake"

class E2eRebuildingPairRakeTest < ActiveSupport::TestCase
  setup do
    unless Rake::Task.task_defined?("e2e:rebuilding_pair_seed")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/e2e.rake").to_s }
    end
    Rake::Task["e2e:rebuilding_pair_seed"].reenable
    Rake::Task["e2e:rebuilding_pair_cleanup"].reenable
  end

  test "seeds a pending pair hidden as being rebuilt, idempotently, and cleans it up" do
    out, = capture_io { Rake::Task["e2e:rebuilding_pair_seed"].invoke }
    Rake::Task["e2e:rebuilding_pair_seed"].reenable
    capture_io { Rake::Task["e2e:rebuilding_pair_seed"].invoke }

    pair = DuplicateCandidate.find(JSON.parse(out.lines.last)["pair_id"])
    assert pair.pending?
    assert_equal [pair.id], Services::DuplicateCandidates::BeingRebuilt.only(DuplicateCandidate.where(id: pair.id)).pluck(:id)
    assert_equal 1, Books::RepairVerdict.where(subject_key: "e2e:rebuilding_mixed").count

    capture_io { Rake::Task["e2e:rebuilding_pair_cleanup"].invoke }
    assert_not DuplicateCandidate.exists?(pair.id)
    assert_equal 0, Books::RepairVerdict.where(subject_key: "e2e:rebuilding_mixed").count
    assert_equal 0, Books::Book.where(title: ["E2E Rebuilding Mixed Book", "E2E Rebuilding Other Book"]).count
  end
end
