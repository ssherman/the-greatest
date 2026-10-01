# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    class DeferredEnrichmentTest < ActiveSupport::TestCase
      def setup
        @author = ::Books::Author.create!(name: "Anna Brenner")
      end

      def book_by_author(title)
        ::Books::Book.create!(title: title).tap { |book| book.book_authors.create!(author: @author, position: 1) }
      end

      test "defer! writes a skipped book facts row with the deferral reason" do
        row = DeferredEnrichment.defer!(book_by_author("The Quiet Year"))

        assert_equal ["books.book_facts", "skipped", "deferred_to_authors"], [row.kind, row.outcome, row.reason]
      end

      test "the waiting books are the author's books whose latest book facts row is the deferral" do
        waiting = book_by_author("The Quiet Year")
        DeferredEnrichment.defer!(waiting)
        enriched_since = book_by_author("Enriched Since")
        DeferredEnrichment.defer!(enriched_since)
        enriched_since.enrichments.create!(kind: EnrichBook::KIND, outcome: :applied)
        book_by_author("Never Waited")
        DeferredEnrichment.defer!(::Books::Book.create!(title: "Someone Else's"))

        assert_equal [waiting.id], DeferredEnrichment.waiting_book_ids(@author)
      end

      test "an author with no books has none waiting" do
        assert_equal [], DeferredEnrichment.waiting_book_ids(@author)
      end
    end
  end
end
