require "test_helper"

# == Schema Information
#
# Table name: books_publisher_intake_runs
#
#  id          :bigint           not null, primary key
#  baseline    :boolean          default(FALSE), not null
#  counts      :jsonb            not null
#  error       :text
#  finished_at :datetime
#  kind        :integer          default("weekly"), not null
#  source      :string           not null
#  started_at  :datetime         not null
#  status      :integer          default("running"), not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#
# Indexes
#
#  index_books_publisher_intake_runs_on_source_and_started_at  (source,started_at)
#
class Books::PublisherIntakeRunTest < ActiveSupport::TestCase
  test "a run needs a source and a start time" do
    assert_not Books::PublisherIntakeRun.new(started_at: Time.current).valid?
    assert_not Books::PublisherIntakeRun.new(source: "hachette_us").valid?
    assert Books::PublisherIntakeRun.new(source: "hachette_us", started_at: Time.current).valid?
  end

  test "counts default to an empty hash" do
    assert_equal({}, Books::PublisherIntakeRun.new.counts)
  end

  test "a new run is a weekly, running, non-baseline run" do
    run = Books::PublisherIntakeRun.new
    assert run.kind_weekly?
    assert run.status_running?
    assert_equal false, run.baseline
  end

  test "for_source returns only that source's runs" do
    assert_equal [books_publisher_intake_runs(:finished_run)], Books::PublisherIntakeRun.for_source("hachette_us").to_a
  end
end
