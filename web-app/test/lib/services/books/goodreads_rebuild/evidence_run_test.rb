# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsRebuild
      class EvidenceRunTest < ActiveSupport::TestCase
        setup do
          @import = books_goodreads_imports(:regular_user_import)
          @books = (1..2).map { |i| ::Books::Book.create!(title: "Derived #{i}") }
          Cohort.stubs(:derived).returns(::Books::Book.where(id: @books.map(&:id)))
          ::Books::OpenLibrary::Configuration.any_instance.stubs(:base_url).returns("http://localhost:8101")
          ::Books::WorldCat::Configuration.any_instance.stubs(:base_url).returns("http://127.0.0.1:8102")
          @editions = @books.each_with_index.map do |book, index|
            edition = ::Books::GoodreadsEdition.create!(goodreads_book_id: 5_000 + index, signature: "sig-#{index}", title: "T#{index}",
              primary_author: "Jane Doe")
            ::Books::GoodreadsImportRow.create!(import: @import, row_number: 4_000 + index, raw: {}, goodreads_edition: edition,
              legacy_book_id: book.id)
            edition
          end
        end

        test "refuses when a service is not local" do
          ::Books::OpenLibrary::Configuration.any_instance.stubs(:base_url).returns("https://ol-api.thegreatestbooks.org")
          GatherEvidence.expects(:call).never

          result = EvidenceRun.call

          assert result.data[:stopped]
          assert_equal "point OPEN_LIBRARY_SERVICE_URL and WORLDCAT_SERVICE_URL at local instances", result.data[:error]
        end

        test "gathers evidence for derived editions without it" do
          ::Books::RebuildEditionEvidence.create!(goodreads_book_id: 5_001, signature: "sig-1", world_cat: :no_record, checked_at: Time.current)
          seen = Queue.new
          GatherEvidence.stubs(:call).with { |edition:, **| seen << edition.id }.returns(nil)

          result = EvidenceRun.call(threads: 2)

          assert_equal [@editions.first.id], Array.new(seen.size) { seen.pop }
          assert_equal 1, result.data[:looked_up]
          refute result.data[:stopped]
        end

        test "the limit caps the editions" do
          GatherEvidence.expects(:call).once.returns(nil)

          assert_equal 1, EvidenceRun.call(threads: 1, limit: 1).data[:looked_up]
        end

        # The first full-speed dev run got 504s from a saturated local WorldCat.
        test "a busy service is retried after a pause" do
          pauses = []
          GatherEvidence.stubs(:call).raises(::Books::WorldCat::Exceptions::ServerError.new("Server error: 504", 504))
            .then.returns(nil)

          result = EvidenceRun.call(threads: 1, sleeper: ->(seconds) { pauses << seconds })

          refute result.data[:stopped]
          assert_equal 2, result.data[:looked_up]
          assert_equal [EvidenceRun::PAUSES.first], pauses
        end

        # Final review: both services' circuit breakers open for 60 s after 5
        # failures, so a shorter pause only meets CircuitOpenError.
        test "every pause outlasts the services' circuit breaker cooldown" do
          assert_operator EvidenceRun::PAUSES.min, :>, EvidenceRun::BREAKER_COOLDOWN
        end

        test "a non-service error stops the run cleanly instead of killing one worker" do
          GatherEvidence.stubs(:call).raises(ActiveRecord::ConnectionTimeoutError, "pool")

          result = EvidenceRun.call(threads: 2, sleeper: ->(_) {})

          assert result.data[:stopped]
          assert_match(/ConnectionTimeoutError: pool/, result.data[:error])
        end

        test "a service error that persists stops the run after every pause" do
          pauses = []
          GatherEvidence.stubs(:call).raises(::Books::OpenLibrary::Exceptions::Error, "down")

          result = EvidenceRun.call(threads: 1, sleeper: ->(seconds) { pauses << seconds })
          assert_equal EvidenceRun::PAUSES, pauses

          assert result.data[:stopped]
          assert_match(/down/, result.data[:error])
          assert_equal 0, result.data[:looked_up]
        end
      end
    end
  end
end
