require "test_helper"

module Books
  module GoodreadsReplay
    class ResolveEditionJobTest < ActiveSupport::TestCase
      include GoodreadsImportHelper

      RESOLVE = ::Services::Books::GoodreadsReplay::ResolveEdition

      setup do
        @edition = goodreads_edition
        @import = ::Books::GoodreadsImport.create!(user: users(:regular_user), source: :legacy_replay, status: :complete, legacy_import_id: 7)
        @row = @import.rows.create!(row_number: 1, goodreads_edition: @edition)
      end

      def answer(needs_full_pass)
        RESOLVE::Result.new(success?: true, data: {needs_full_pass: needs_full_pass, tally: {}}, errors: [])
      end

      test "pass one resolves the edition, and queues pass two on serial when it disagreed" do
        RESOLVE.expects(:call).with(edition: @edition, pass: 1).returns(answer(true))
        RESOLVE.expects(:call).with(edition: @edition, pass: 2).returns(answer(false))

        Sidekiq::Testing.fake! do
          ResolveEditionJob.clear
          ResolveEditionJob.new.perform(@edition.id, 1)
          job = ResolveEditionJob.jobs.sole
          assert_equal "serial", job["queue"]
          assert_equal [@edition.id, 2], job["args"]
          ResolveEditionJob.drain
        end
      end

      test "pass one is skipped for an edition whose replay rows all have findings" do
        @row.update!(replay_finding: :agrees)
        RESOLVE.expects(:call).never

        ResolveEditionJob.new.perform(@edition.id, 1)
      end

      test "a missing edition is nothing to do" do
        RESOLVE.expects(:call).never

        ResolveEditionJob.new.perform(0, 1)
      end

      test "enqueue_pending queues pass one for rows without findings and pass two for rows awaiting it" do
        waiting = goodreads_edition(title: "Another Book")
        @import.rows.create!(row_number: 2, goodreads_edition: waiting, replay_finding: :awaiting_full_pass)
        member = ::Books::GoodreadsImport.create!(user: users(:editor_user), source: :member, status: :complete)
        member.rows.create!(row_number: 1, goodreads_edition: goodreads_edition(title: "Member Only"))

        Sidekiq::Testing.fake! do
          ResolveEditionJob.clear
          assert_equal({first_pass: 1, full_pass: 1}, ResolveEditionJob.enqueue_pending)
          assert_equal [[@edition.id, 1], [waiting.id, 2]].sort, ResolveEditionJob.jobs.map { |job| job["args"] }.sort
          assert_equal %w[low serial], ResolveEditionJob.jobs.map { |job| job["queue"] }.sort
        end
      end
    end
  end
end
