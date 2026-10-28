# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsRebuild
      class SurveyTest < ActiveSupport::TestCase
        setup do
          @import = books_goodreads_imports(:regular_user_import)
          @books = (1..3).map { |i| ::Books::Book.create!(title: "Derived #{i}") }
          Cohort.stubs(:derived).returns(::Books::Book.where(id: @books.map(&:id)))
          @row_number = 3_000
        end

        def row(book_id, title)
          edition = ::Books::GoodreadsEdition.create!(goodreads_book_id: @row_number, signature: "sig-#{@row_number}", title: title,
            primary_author: "Jane Doe", original_publication_year: 2001)
          ::Books::GoodreadsImportRow.create!(import: @import, row_number: (@row_number += 1), raw: {}, goodreads_edition: edition,
            legacy_book_id: book_id)
        end

        test "surveys derived books without a survey, up to the limit" do
          result = Survey.call(limit: 2)

          assert_equal 2, result.data[:processed]
          refute result.data[:stopped]
          assert_equal @books.first(2).map(&:id), ::Books::RebuildBookSurvey.order(:book_id).pluck(:book_id) & @books.map(&:id)
        end

        test "a limit larger than one batch still stops at the limit" do
          result = Survey.call(limit: 2, batch_size: 1)

          assert_equal 2, result.data[:processed]
          assert_equal 2, ::Books::RebuildBookSurvey.where(book: @books).count
        end

        test "skips books already surveyed unless resurvey" do
          Survey.call(limit: nil)
          surveyed_at = ::Books::RebuildBookSurvey.where(book: @books).maximum(:surveyed_at)

          assert_equal 0, Survey.call(limit: nil).data[:processed]
          travel 1.minute do
            assert_equal 3, Survey.call(limit: nil, resurvey: true).data[:processed]
          end
          assert_operator ::Books::RebuildBookSurvey.where(book: @books).minimum(:surveyed_at), :>, surveyed_at
        end

        test "a book's rows on a merged-away id are found across batches" do
          row(@books.last.id, "Own row")
          row(999_997, "Row on a merged-away book")
          ::Services::Books::GoodreadsReplay::Apply::MergedBook.stubs(:call).returns(nil)
          ::Services::Books::GoodreadsReplay::Apply::MergedBook.stubs(:call).with(999_997).returns(@books.last)

          Survey.call(limit: nil, batch_size: 1)

          survey = ::Books::RebuildBookSurvey.find_by(book: @books.last)
          assert_equal 2, survey.row_count
          assert_equal 0, ::Books::RebuildBookSurvey.find_by(book: @books.first).row_count
        end

        # A real second session: the test connection is shared by every pool
        # checkout, and an advisory lock is re-entrant in one session.
        test "a second run while one holds the lock stops at once" do
          config = ActiveRecord::Base.connection_db_config.configuration_hash
          session = PG.connect(dbname: config[:database], host: config[:host], port: config[:port], user: config[:username],
            password: config[:password])
          assert_equal "t", session.exec("SELECT pg_try_advisory_lock(#{Survey::LOCK_KEY})").getvalue(0, 0)

          result = Survey.call(limit: nil)

          assert result.data[:stopped]
          assert_equal "another survey run is in progress", result.data[:error]
          assert_equal 0, ::Books::RebuildBookSurvey.where(book: @books).count
        ensure
          session&.exec("SELECT pg_advisory_unlock(#{Survey::LOCK_KEY})")
          session&.close
        end
      end
    end
  end
end
