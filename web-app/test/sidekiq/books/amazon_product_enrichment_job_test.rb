# frozen_string_literal: true

require "test_helper"

class Books::AmazonProductEnrichmentJobTest < ActiveSupport::TestCase
  def setup
    @book = books_books(:war_and_peace)
  end

  test "perform calls the books Amazon service with the book" do
    ::Services::Books::AmazonProductService.expects(:call).with(book: @book).returns(
      {success: true, data: "Enrichment completed"}
    )

    Books::AmazonProductEnrichmentJob.new.perform(@book.id)
  end

  test "perform stamps amazon_enriched_at on success" do
    ::Services::Books::AmazonProductService.stubs(:call).returns({success: true, data: "ok"})

    Books::AmazonProductEnrichmentJob.new.perform(@book.id)

    assert_not_nil @book.reload.amazon_enriched_at
  end

  test "perform raises so Sidekiq retries when the service fails" do
    ::Services::Books::AmazonProductService.stubs(:call).returns({success: false, error: "API error"})

    error = assert_raises(StandardError) do
      Books::AmazonProductEnrichmentJob.new.perform(@book.id)
    end

    assert_match(/API error/, error.message)
  end

  test "perform stamps amazon_enriched_at even when the service fails" do
    ::Services::Books::AmazonProductService.stubs(:call).returns({success: false, error: "API error"})

    assert_raises(StandardError) do
      Books::AmazonProductEnrichmentJob.new.perform(@book.id)
    end

    assert_not_nil @book.reload.amazon_enriched_at
  end

  test "perform logs loudly when a successful result still carries per-product errors" do
    ::Services::Books::AmazonProductService.stubs(:call).returns(
      {success: true, data: "2 products, 0 links created", errors: ["Failed to persist ASIN 1: boom", "Failed to persist ASIN 2: boom"]}
    )

    Rails.logger.expects(:error).with(
      "Amazon enrichment for #{@book.title} succeeded with 2 per-product failures: Failed to persist ASIN 1: boom; Failed to persist ASIN 2: boom"
    )

    Books::AmazonProductEnrichmentJob.new.perform(@book.id)
  end

  # Books::Book uses friendly_id with :finders, so a STRING id resolves by slug.
  # 137 books have purely numeric slugs that shadow real ids in production; no
  # fixture book has one, so the collision is built here: a second book whose
  # slug is the string form of @book.id.
  test "perform resolves the book by primary key even when given a string id that collides with another book's slug" do
    colliding = ::Books::Book.create!(title: "Colliding Book", slug: @book.id.to_s)
    ::Services::Books::AmazonProductService.stubs(:call).returns({success: true, data: "ok"})

    Books::AmazonProductEnrichmentJob.new.perform(@book.id.to_s)

    assert_not_nil @book.reload.amazon_enriched_at
    assert_nil colliding.reload.amazon_enriched_at
  end

  test "job is configured for the serial queue" do
    assert_equal :serial, Books::AmazonProductEnrichmentJob.get_sidekiq_options["queue"]
  end
end
