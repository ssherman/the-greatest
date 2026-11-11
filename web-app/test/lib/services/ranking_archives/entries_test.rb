# frozen_string_literal: true

require "test_helper"

module Services
  module RankingArchives
    class EntriesTest < ActiveSupport::TestCase
      setup do
        @first = books_books(:war_and_peace)
        @second = books_books(:crime_and_punishment)
        @third = books_books(:cannery_row)
      end

      def archive_of(ids, positions: nil, scores: nil)
        ::Books::RankingArchive.create!(
          name: "T #{SecureRandom.hex(4)}", captured_at: Time.current,
          item_ids: ids, positions: positions || (1..ids.size).to_a, scores: scores || ids.each_index.map { |i| 100 - i }
        )
      end

      def entries(archive, offset: 0, limit: 100, preload: [])
        Entries.call(archive: archive, offset: offset, limit: limit, preload: preload)
      end

      def new_book(title = "Book #{SecureRandom.hex(4)}")
        ::Books::Book.create!(title: title, book_kind: :standalone)
      end

      def redirect!(from_id, to_id)
        ::RecordRedirect.create!(item_type: "Books::Book", from_id: from_id, to_id: to_id)
      end

      def missing_id
        (::Books::Book.maximum(:id) || 0) + 1_000_000 + rand(1000)
      end

      test "a live book is returned with its archived rank and score" do
        archive = archive_of([@first.id], positions: [4], scores: [88.5])

        entry = entries(archive).sole

        assert_equal @first, entry.item
        assert_equal 4, entry.rank
        assert_equal 88.5, entry.score
      end

      test "positions are the archived ones, gaps included" do
        archive = archive_of([@first.id, @second.id], positions: [1, 3])

        assert_equal [1, 3], entries(archive).map(&:rank)
      end

      test "a merged id is shown as its survivor at the archived position" do
        survivor = new_book
        gone_id = missing_id
        redirect!(gone_id, survivor.id)
        archive = archive_of([gone_id], positions: [7])

        entry = entries(archive).sole

        assert_equal survivor, entry.item
        assert_equal 7, entry.rank
      end

      test "a survivor already archived at a better position drops the merged slot" do
        survivor = new_book
        gone_id = missing_id
        redirect!(gone_id, survivor.id)
        archive = archive_of([survivor.id, gone_id])

        entry = entries(archive).sole

        assert_equal survivor, entry.item
        assert_equal 1, entry.rank
      end

      test "a survivor archived at a worse position is dropped there and kept at the merged slot" do
        survivor = new_book
        gone_id = missing_id
        redirect!(gone_id, survivor.id)
        archive = archive_of([gone_id, survivor.id], positions: [1, 2])

        entry = entries(archive).sole

        assert_equal survivor, entry.item
        assert_equal 1, entry.rank
      end

      test "the dedupe holds across pages" do
        survivor = new_book
        gone_id = missing_id
        redirect!(gone_id, survivor.id)
        archive = archive_of([gone_id, @first.id, survivor.id])

        assert_equal [], entries(archive, offset: 2, limit: 1)
        assert_equal [survivor], entries(archive, offset: 0, limit: 1).map(&:item)
      end

      # A redirect whose source is a live book is stale: a full migration can bring a merged book back
      # and leave its row behind until sync_init removes it. `resolve` shows that book as itself, so
      # the row must not also count as an alias of its target and take the target's slot away.
      test "a stale redirect whose source is still live does not hide its target" do
        archive = archive_of([@first.id, @second.id])
        redirect!(@first.id, @second.id)

        result = entries(archive)

        assert_equal [@first, @second], result.map(&:item)
        assert_equal [1, 2], result.map(&:rank)
      end

      test "a stale redirect from a live book outside the page does not hide its target" do
        archive = archive_of([@first.id, @third.id, @second.id])
        redirect!(@first.id, @second.id)

        assert_equal [@second], entries(archive, offset: 2, limit: 1).map(&:item)
      end

      test "an id redirected to nothing is skipped" do
        gone_id = missing_id
        redirect!(gone_id, nil)
        archive = archive_of([gone_id, @first.id])

        assert_equal [@first], entries(archive).map(&:item)
      end

      test "an id with no book and no redirect is skipped" do
        archive = archive_of([missing_id, @first.id])

        assert_equal [@first], entries(archive).map(&:item)
      end

      test "a destroyed book is skipped" do
        doomed = new_book
        archive = archive_of([doomed.id, @first.id])
        doomed.destroy!

        assert_equal [@first], entries(archive).map(&:item)
      end

      test "every id gone returns an empty array" do
        archive = archive_of([missing_id, missing_id + 1])

        assert_equal [], entries(archive)
      end

      test "an offset past the end returns an empty array" do
        archive = archive_of([@first.id])

        assert_equal [], entries(archive, offset: 5, limit: 10)
      end

      test "offset and limit slice the archive" do
        archive = archive_of([@first.id, @second.id, @third.id])

        assert_equal [@second], entries(archive, offset: 1, limit: 1).map(&:item)
        assert_equal [@second, @third], entries(archive, offset: 1, limit: 10).map(&:item)
      end

      test "preload is applied" do
        archive = archive_of([@first.id])

        entry = entries(archive, preload: [:book_authors]).sole

        assert entry.item.association(:book_authors).loaded?
      end

      test "through the real merger: an archived new-app book is shown as its survivor and the archive is untouched" do
        source = ::Books::Book.create!(title: "Archived Then Merged", book_kind: :standalone)
        archive = ::Books::RankingArchive.create!(name: "T", captured_at: Time.current,
          item_ids: [source.id], positions: [1], scores: [10])
        target = ::Books::Book.create!(title: "Survivor", book_kind: :standalone)
        ::Services::RankingConfigurations::RequestRefresh.expects(:call_for_ids).with([], delay: 5.minutes)

        assert_no_changes -> { archive.reload.attributes } do
          ::Books::Book::Merger.call(source: source, target: target)
        end

        assert_equal [target], entries(archive).map(&:item)
      end
    end
  end
end
