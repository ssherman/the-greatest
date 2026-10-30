# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsRebuild
      class DecideFixesTest < ActiveSupport::TestCase
        setup do
          @base = Cohort.post_import_range.first + 8_000
          @next_id = 0
        end

        def derived_book
          ::Books::Book.create!(id: @base + (@next_id += 1), title: "Derived #{@next_id}")
        end

        def survey_for(book, classification: :coherent, title_agrees: false, authors_agree: false, wrong_book: false)
          ::Books::RebuildBookSurvey.create!(book: book, classification: classification, groups: [], title_agrees: title_agrees,
            authors_agree: authors_agree, wrong_book: wrong_book, surveyed_at: Time.current)
        end

        def list(book, times)
          lists = [user_lists(:regular_user_books_read), user_lists(:regular_user_books_favorites)]
          lists.first(times).each { |l| UserListItem.create!(user_list: l, listable: book) }
        end

        test "candidates order the most-listed book first and leave out trusted, agreeing and unsupported books" do
          few = survey_for(derived_book).book
          many = survey_for(derived_book, classification: :lump).book
          list(many, 2)
          list(few, 1)
          survey_for(derived_book, title_agrees: true, authors_agree: true)
          survey_for(derived_book, classification: :unsupported, title_agrees: nil, authors_agree: nil)
          trusted = survey_for(::Books::Book.create!(id: Cohort.post_import_range.first - 1_000, title: "Trusted")).book

          ids = DecideFixes.candidates.pluck(:id)

          assert_equal [many.id, few.id], ids
          refute_includes ids, trusted.id
        end

        test "candidates agree with DecideFix.needs_fix? on every kind of survey" do
          surveys = [
            survey_for(derived_book, title_agrees: true, authors_agree: true),
            survey_for(derived_book, title_agrees: false, authors_agree: true),
            survey_for(derived_book, classification: :lump, title_agrees: true, authors_agree: false),
            survey_for(derived_book, title_agrees: true, authors_agree: true, wrong_book: true),
            survey_for(derived_book, classification: :unsupported, title_agrees: false, authors_agree: false),
            survey_for(derived_book, classification: :unsupported, title_agrees: nil, authors_agree: nil),
            survey_for(derived_book, title_agrees: nil, authors_agree: nil),
            survey_for(derived_book, classification: :lump, title_agrees: true, authors_agree: true)
          ]

          expected = surveys.select { |s| DecideFix.needs_fix?(s) }.map(&:book_id)

          assert_equal expected.sort, DecideFixes.candidates.pluck(:id).sort
          assert_operator expected.size, :>=, 3
        end

        test "enqueue slices into batches of 100 and respects limit" do
          250.times { survey_for(derived_book) }

          Sidekiq::Testing.fake! do
            ::Books::GoodreadsRebuild::DecideFixesJob.clear
            assert_equal 150, DecideFixes.enqueue(limit: 150)
            assert_equal [100, 50], ::Books::GoodreadsRebuild::DecideFixesJob.jobs.map { |j| j["args"].first.size }
            ::Books::GoodreadsRebuild::DecideFixesJob.clear
            assert_equal 250, DecideFixes.enqueue(limit: nil)
            assert_equal [100, 100, 50], ::Books::GoodreadsRebuild::DecideFixesJob.jobs.map { |j| j["args"].first.size }
          ensure
            ::Books::GoodreadsRebuild::DecideFixesJob.clear
          end
        end
      end
    end
  end
end
