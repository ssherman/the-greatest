# frozen_string_literal: true

require "test_helper"

class Books::ReindexRankedFieldsJobTest < ActiveSupport::TestCase
  test "sends each ranked book's current rank to the index" do
    book = books_books(:war_and_peace)
    RankedItem.create!(
      item: book,
      ranking_configuration: ranking_configurations(:books_global),
      rank: 5,
      score: 88.0
    )

    Search::Books::BookIndex.expects(:bulk_update).with { |updates| updates[book.id] == {ranked_position: 5, ranked: false} }

    Books::ReindexRankedFieldsJob.new.perform
  end

  test "writes ranked: true for a ranked book with a list item and ranked: false for one without" do
    listed_book = books_books(:war_and_peace)
    unlisted_book = books_books(:crime_and_punishment)
    ListItem.create!(list: lists(:books_list), listable: listed_book, position: 1)
    RankedItem.create!(
      item: listed_book,
      ranking_configuration: ranking_configurations(:books_global),
      rank: 1,
      score: 95.0
    )
    RankedItem.create!(
      item: unlisted_book,
      ranking_configuration: ranking_configurations(:books_global),
      rank: 2,
      score: 90.0
    )

    Search::Books::BookIndex.expects(:bulk_update).with do |updates|
      updates[listed_book.id] == {ranked_position: 1, ranked: true} &&
        updates[unlisted_book.id] == {ranked_position: 2, ranked: false}
    end

    Books::ReindexRankedFieldsJob.new.perform
  end

  test "ignores ranks from non-primary ranking configurations" do
    book = books_books(:war_and_peace)
    # A companion ranked item in the primary config so the batch isn't empty --
    # otherwise `in_batches` never yields and `bulk_update` is never called at all.
    RankedItem.create!(
      item: books_books(:crime_and_punishment),
      ranking_configuration: ranking_configurations(:books_global),
      rank: 1,
      score: 90.0
    )
    RankedItem.create!(
      item: book,
      ranking_configuration: ranking_configurations(:books_user),
      rank: 3,
      score: 70.0
    )

    Search::Books::BookIndex.expects(:bulk_update).with { |updates| !updates.key?(book.id) }

    Books::ReindexRankedFieldsJob.new.perform
  end

  test "skips ranked items with a nil rank" do
    book = books_books(:war_and_peace)
    # A companion ranked item in the primary config so the batch isn't empty --
    # otherwise `in_batches` never yields and `bulk_update` is never called at all.
    RankedItem.create!(
      item: books_books(:crime_and_punishment),
      ranking_configuration: ranking_configurations(:books_global),
      rank: 1,
      score: 90.0
    )
    RankedItem.create!(
      item: book,
      ranking_configuration: ranking_configurations(:books_global),
      rank: nil,
      score: 60.0
    )

    Search::Books::BookIndex.expects(:bulk_update).with { |updates| !updates.key?(book.id) }

    Books::ReindexRankedFieldsJob.new.perform
  end

  test "raises when there is no primary books ranking configuration" do
    Books::RankingConfiguration.stubs(:default_primary).returns(nil)

    assert_raises(RuntimeError) { Books::ReindexRankedFieldsJob.new.perform }
  end

  test "raises and reports the failure count when bulk_update reports per-item errors" do
    book = books_books(:war_and_peace)
    RankedItem.create!(
      item: book,
      ranking_configuration: ranking_configurations(:books_global),
      rank: 4,
      score: 85.0
    )

    Search::Books::BookIndex.stubs(:bulk_update).returns(
      "errors" => true,
      "items" => [{"update" => {"_id" => book.id.to_s, "error" => {"type" => "document_missing_exception"}}}]
    )

    error = assert_raises(RuntimeError) { Books::ReindexRankedFieldsJob.new.perform }
    assert_match(/1\/1/, error.message)
  end

  test "does not raise when bulk_update succeeds without errors" do
    book = books_books(:war_and_peace)
    RankedItem.create!(
      item: book,
      ranking_configuration: ranking_configurations(:books_global),
      rank: 6,
      score: 82.0
    )

    Search::Books::BookIndex.stubs(:bulk_update).returns("errors" => false, "items" => [])

    assert_nothing_raised { Books::ReindexRankedFieldsJob.new.perform }
  end
end
