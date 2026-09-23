# frozen_string_literal: true

require "test_helper"

class Books::FindDuplicatesJobTest < ActiveSupport::TestCase
  def setup
    @book = books_books(:war_and_peace)
    @other = books_books(:crime_and_punishment)
    @decision = match_decisions(:low_confidence_book_match)
  end

  test "runs on the serial queue" do
    assert_equal "serial", Books::FindDuplicatesJob.get_sidekiq_options["queue"].to_s
  end

  test "resolves the book against the rest of the catalog: its own fields as the query, verify, subject and exclude set" do
    isbn = identifiers(:war_and_peace_isbn13).value
    asin = identifiers(:war_and_peace_asin).value
    DataImporters::Books::Book::Finder.any_instance.expects(:call).with do |args|
      query = args[:query]
      query.title == "War and Peace" && query.author_names == ["Leo Tolstoy"] && query.year == 1869 &&
        query.isbn13 == [isbn] && query.asin == [asin] && query.open_library_work_key.nil? &&
        args[:verify] == true && args[:subject] == @book && args[:exclude] == @book
    end.returns(DataImporters::Match.new(outcome: :unmatched, confidence: :high, decided_by: :rule))

    assert_no_difference("DuplicateCandidate.count") { Books::FindDuplicatesJob.new.perform(@book.id) }
  end

  test "the book's Open Library key travels as open_library_work_key" do
    DataImporters::Books::Book::Finder.any_instance.expects(:call).with { |args| args[:query].open_library_work_key == "OL262758W" }
      .returns(DataImporters::Match.new(outcome: :unmatched))

    Books::FindDuplicatesJob.new.perform(@other.id)
  end

  test "a match flags the pair as bulk_verify with the decision's reason and the decision itself" do
    DataImporters::Books::Book::Finder.any_instance.stubs(:call).returns(
      DataImporters::Match.new(outcome: :matched, record: @other, confidence: :high, decided_by: :ai, reason: "Same work, other title.", decision: @decision)
    )

    assert_difference("DuplicateCandidate.count", 1) { Books::FindDuplicatesJob.new.perform(@book.id) }

    pair = DuplicateCandidate.last
    assert_equal ["Books::Book", [@book.id, @other.id].min, [@book.id, @other.id].max], [pair.item_type, pair.item_a_id, pair.item_b_id]
    assert pair.raised_by_bulk_verify?
    assert_equal({"reason" => "Same work, other title.", "decided_by" => "ai", "confidence" => "high"}, pair.evidence)
    assert_equal @decision, pair.match_decision
  end

  test "the sweep caps identifiers per type: a book with five ISBN-13 rows sends the finder three" do
    4.times { |i| @book.identifiers.create!(identifier_type: :books_work_isbn13, value: "isbn-cap-#{i}") }
    assert_equal 5, @book.identifiers.where(identifier_type: :books_work_isbn13).count
    DataImporters::Books::Book::Finder.any_instance.expects(:call).with { |args| args[:query].isbn13.size == 3 }
      .returns(DataImporters::Match.new(outcome: :unmatched))

    Books::FindDuplicatesJob.new.perform(@book.id)
  end

  test "a match decided with the Open Library source failed raises instead of flagging a degraded pair" do
    DataImporters::Books::Book::Finder.any_instance.stubs(:call).returns(
      DataImporters::Match.new(outcome: :matched, record: @other, confidence: :medium, decided_by: :rule,
        reason: "Exact title and author match.", sources_failed: ["open_library"])
    )

    assert_no_difference("DuplicateCandidate.count") do
      assert_raises(Books::FindDuplicatesJob::SourceFailed) { Books::FindDuplicatesJob.new.perform(@book.id) }
    end
  end

  test "a missing book is skipped without calling the finder" do
    DataImporters::Books::Book::Finder.any_instance.expects(:call).never

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
