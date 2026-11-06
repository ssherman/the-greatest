# frozen_string_literal: true

require "test_helper"

module Workflows
  module Books
    module Steps
      class AmazonTest < ActiveSupport::TestCase
        setup do
          @book = books_books(:got)
          stub_workflow_dispatch
          freeze_time
        end

        def call
          run = BookEnrichment.start(@book, initiated_by: "test")
          Amazon.new.call(step: run.step(:amazon), run: run, target: @book)
        end

        test "succeeds and stamps amazon_enriched_at" do
          ::Services::Books::AmazonProductService.expects(:call).with(book: @book).returns({success: true, data: {products: 2}, errors: []})

          result = call

          assert_equal [:succeeded, "done"], [result.kind, result.outcome]
          assert_equal Time.current, @book.reload.amazon_enriched_at
        end

        test "per-product failures are logged and do not fail the step" do
          ::Services::Books::AmazonProductService.stubs(:call).returns({success: true, data: {}, errors: ["B001 bad"]})
          Rails.logger.stubs(:info)
          Rails.logger.expects(:error).with(regexp_matches(/succeeded with 1 per-product failures: B001 bad/))

          assert_equal :succeeded, call.kind
        end

        test "stamps amazon_enriched_at even when the service fails, and raises" do
          ::Services::Books::AmazonProductService.stubs(:call).returns({success: false, errors: ["nope", "worse"]})

          error = assert_raises(StandardError) { call }

          assert_equal "Amazon enrichment failed: nope, worse", error.message
          assert_equal Time.current, @book.reload.amazon_enriched_at
        end

        test "a single error string is reported in the message" do
          ::Services::Books::AmazonProductService.stubs(:call).returns({success: false, error: "no match"})

          error = assert_raises(StandardError) { call }

          assert_equal "Amazon enrichment failed: no match", error.message
        end
      end
    end
  end
end
