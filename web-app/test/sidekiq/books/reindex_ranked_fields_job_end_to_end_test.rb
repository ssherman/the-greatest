# frozen_string_literal: true

require "test_helper"

class Books::ReindexRankedFieldsJobEndToEndTest < ActiveSupport::TestCase
  def setup
    cleanup_test_index
    ::Search::Books::BookIndex.create_index
  end

  def teardown
    cleanup_test_index
  end

  test "refreshes ranked_position and ranked on a real index document" do
    book = books_books(:war_and_peace)
    ::Search::Books::BookIndex.index_item(book)

    RankedItem.create!(
      item: book,
      ranking_configuration: ranking_configurations(:books_global),
      rank: 9,
      score: 77.0
    )
    ListItem.create!(list: lists(:books_list), listable: book, position: 1)

    Books::ReindexRankedFieldsJob.new.perform

    doc = ::Search::Books::BookIndex.find_by_id(book.id)
    assert_equal 9, doc["ranked_position"]
    assert_equal true, doc["ranked"]
  end

  private

  def cleanup_test_index
    ::Search::Books::BookIndex.delete_index
  rescue OpenSearch::Transport::Transport::Errors::NotFound
  end
end
