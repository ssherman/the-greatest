# frozen_string_literal: true

require "test_helper"

module Books
  module AlternateTitles
    class ReviewJobTest < ActiveSupport::TestCase
      setup do
        @config = ranking_configurations(:books_global)
        @second = books_books(:clash)
        @first = books_books(:got)
        @unranked = books_books(:of_mice_and_men)
        [@first, @second, @unranked].each do |book|
          AlternateTitle.create!(titleable: book, title: "Alt #{book.id}", source: :legacy, status: :kept)
        end
        RankedItem.create!(item: @second, ranking_configuration: @config, rank: 2, score: 1.0)
        RankedItem.create!(item: @first, ranking_configuration: @config, rank: 1, score: 1.0)
      end

      test "pending ranked comes first by rank" do
        ids = ReviewJob.pending_book_ids("all")

        assert_equal [@first.id, @second.id], ids.first(2)
        assert_equal [books_books(:war_and_peace).id, @unranked.id].sort, ids.drop(2).sort
        assert_equal ids.drop(2).sort, ids.drop(2)
        assert_equal [@first.id, @second.id], ReviewJob.pending_book_ids("ranked")
      end

      test "count scope takes the first n" do
        assert_equal [@first.id], ReviewJob.pending_book_ids("1")
        assert_equal ReviewJob.pending_book_ids("all").first(3), ReviewJob.pending_book_ids("3")
      end

      test "books with nothing unjudged are not queued" do
        AlternateTitle.where(titleable: @first).update_all(verdict: AlternateTitle.verdicts[:same_work])

        refute_includes ReviewJob.pending_book_ids("all"), @first.id
        refute_includes ReviewJob.pending_book_ids("all"), books_books(:crime_and_punishment).id
      end

      test "a book with an array but no rows yet is pending" do
        book = books_books(:cannery_row)
        book.update_columns(alternate_titles: ["Tortilla Row"])

        assert_includes ReviewJob.pending_book_ids("all"), book.id
      end

      test "an invalid scope raises" do
        assert_raises(ArgumentError) { ReviewJob.pending_book_ids("bogus") }
      end

      test "enqueue returns the count queued" do
        Sidekiq::Testing.fake! do
          assert_equal 2, ReviewJob.enqueue("ranked")
          assert_equal 2, ReviewJob.jobs.size
        end
      end

      test "perform reviews the book" do
        ::Services::Books::AlternateTitles::Review.expects(:call).with(book: @first)
          .returns(::Services::Books::AlternateTitles::Review::Result.new(success?: true, data: {}, errors: []))

        ReviewJob.new.perform(@first.id)
      end

      test "perform raises on failure" do
        ::Services::Books::AlternateTitles::Review.stubs(:call)
          .returns(::Services::Books::AlternateTitles::Review::Result.new(success?: false, data: {}, errors: ["boom"]))

        error = assert_raises(RuntimeError) { ReviewJob.new.perform(@first.id) }
        assert_match(/boom/, error.message)
      end

      test "perform skips a missing book" do
        ::Services::Books::AlternateTitles::Review.expects(:call).never

        ReviewJob.new.perform(0)
      end
    end
  end
end
