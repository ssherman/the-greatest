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

    Search::Books::BookIndex.expects(:bulk_update).with { |updates| updates[book.id] == {ranked_position: 5} }

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
end
