require "test_helper"

class Books::GoodreadsReimport::LinkLegacyBooksJobTest < ActiveSupport::TestCase
  setup do
    @config = Rails.configuration.x.goodreads_reimport
    @was = @config.enabled
  end

  teardown { @config.enabled = @was }

  test "does nothing while the gate is off" do
    @config.enabled = false
    Services::Books::GoodreadsReimport::LinkLegacyBooks.expects(:call).never

    Books::GoodreadsReimport::LinkLegacyBooksJob.new.perform([1, 2])
  end

  test "links the batch's readers and logs the counts" do
    @config.enabled = true
    result = Services::Books::GoodreadsReimport::LinkLegacyBooks::Result.new(success?: true, data: {linked: 3, unlinked: 1}, errors: [])
    Services::Books::GoodreadsReimport::LinkLegacyBooks.expects(:call).with(user_ids: [1, 2]).returns(result)
    Rails.logger.expects(:info).with { |line| line.include?("link_legacy_books batch: 2 users") && line.include?("linked 3") && line.include?("unlinked 1") }

    Books::GoodreadsReimport::LinkLegacyBooksJob.new.perform([1, 2])
  end

  test "enqueue queues the readers with unlinked rows in batches and returns how many" do
    Services::Books::GoodreadsReimport::LinkLegacyBooks.stubs(:user_ids_to_link).returns((1..55).to_a)

    Sidekiq::Testing.fake! do
      Books::GoodreadsReimport::LinkLegacyBooksJob.jobs.clear
      assert_equal 55, Books::GoodreadsReimport::LinkLegacyBooksJob.enqueue
      assert_equal [50, 5], Books::GoodreadsReimport::LinkLegacyBooksJob.jobs.map { |job| job["args"].first.size }
    end
  end
end
