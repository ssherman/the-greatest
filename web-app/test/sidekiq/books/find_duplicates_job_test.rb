# frozen_string_literal: true

require "test_helper"

class Books::FindDuplicatesJobTest < ActiveSupport::TestCase
  def setup
    @book = books_books(:war_and_peace)
    @other = books_books(:crime_and_punishment)
  end

  def result(success, errors: [])
    Services::Books::FindDuplicates::Result.new(success?: success, data: {match: nil, pair: nil}, errors: errors)
  end

  test "runs on the serial queue" do
    assert_equal "serial", Books::FindDuplicatesJob.get_sidekiq_options["queue"].to_s
  end

  test "hands the book to the sweep service" do
    Services::Books::FindDuplicates.expects(:call).with { |args| args[:book] == @book }.returns(result(true))

    Books::FindDuplicatesJob.new.perform(@book.id)
  end

  test "a failed sweep raises so Sidekiq retries the book" do
    Services::Books::FindDuplicates.expects(:call).returns(result(false, errors: ["Open Library source failed for Books::Book##{@book.id}: circuit open"]))

    error = assert_raises(Books::FindDuplicatesJob::SourceFailed) { Books::FindDuplicatesJob.new.perform(@book.id) }
    assert_match(/circuit open/, error.message)
  end

  test "a missing book is skipped without calling the service" do
    Services::Books::FindDuplicates.expects(:call).never

    Books::FindDuplicatesJob.new.perform(0)
  end

  test "enqueue_ranked enqueues one job per book in the primary ranking, best rank first, and returns the count" do
    config = ranking_configurations(:books_global)
    RankedItem.create!(item: @other, ranking_configuration: config, rank: 2, score: 80.0)
    RankedItem.create!(item: @book, ranking_configuration: config, rank: 1, score: 90.0)
    RankedItem.create!(item: books_books(:got), ranking_configuration: config, rank: nil, score: 0.0)

    Sidekiq::Testing.fake! do
      Books::FindDuplicatesJob.clear

      assert_equal 2, Books::FindDuplicatesJob.enqueue_ranked
      assert_equal [@book.id, @other.id], Books::FindDuplicatesJob.jobs.map { |job| job["args"].first }
      assert_equal ["serial"], Books::FindDuplicatesJob.jobs.map { |job| job["queue"] }.uniq
    end
  end

  test "enqueue_ranked honours a limit" do
    config = ranking_configurations(:books_global)
    RankedItem.create!(item: @other, ranking_configuration: config, rank: 2, score: 80.0)
    RankedItem.create!(item: @book, ranking_configuration: config, rank: 1, score: 90.0)

    Sidekiq::Testing.fake! do
      Books::FindDuplicatesJob.clear

      assert_equal 1, Books::FindDuplicatesJob.enqueue_ranked(limit: 1)
      assert_equal [@book.id], Books::FindDuplicatesJob.jobs.map { |job| job["args"].first }
    end
  end

  test "enqueue_ranked raises when there is no primary books ranking configuration" do
    Books::RankingConfiguration.stubs(:default_primary).returns(nil)

    assert_raises(RuntimeError) { Books::FindDuplicatesJob.enqueue_ranked }
  end
end
