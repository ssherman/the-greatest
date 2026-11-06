# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Origin
      class AcceptDisagreementsTest < ActiveSupport::TestCase
        setup do
          @american = ::Books::Country.find_or_create_by!(name: "American")
          @british = ::Books::Country.find_or_create_by!(name: "British")
          @irish = ::Books::Country.find_or_create_by!(name: "Irish")
          @unknown = ::Books::Country.find_or_create_by!(name: "Unknown")
          @book = ::Books::Book.create!(title: "Accept Book", first_published_year: 1900, original_language: languages(:english))
          @book.countries << @american
          @row = @book.enrichments.create!(kind: "books.origin", mode: :knowledge, outcome: :nothing_to_apply,
            facts: {"label" => "r1", "context" => "backfill",
                    "origin" => {"reason" => "disagreement", "country" => "British", "held" => ["American"]}})
        end

        test "accept replaces the held country and stamps the row" do
          result = AcceptDisagreements.call(label: "r1", apply: true)
          assert_equal 1, result.data[:accepted]
          assert_equal ["British"], @book.reload.countries.map(&:name)
          assert @row.reload.facts["accepted_at"].present?
          assert SearchIndexRequest.where(parent: @book, action: :index_item).exists?
        end

        test "a placeholder row beside the real one is replaced too" do
          @book.countries << @unknown
          AcceptDisagreements.call(label: "r1", apply: true)
          assert_equal ["British"], @book.reload.countries.map(&:name)
        end

        test "accept skips a book whose countries changed since the run" do
          @book.book_countries.destroy_all
          @book.countries << @irish
          assert_equal 0, AcceptDisagreements.call(label: "r1", apply: true).data[:accepted]
          assert_equal ["Irish"], @book.reload.countries.map(&:name)
        end

        test "an accepted row is not a candidate again" do
          AcceptDisagreements.call(label: "r1", apply: true)
          assert_empty AcceptDisagreements.call(label: "r1").data[:candidates]
        end

        test "a newer row for the book supersedes the disagreement" do
          @book.enrichments.create!(kind: "books.origin", mode: :knowledge, outcome: :nothing_to_apply,
            facts: {"label" => "r1", "origin" => {"reason" => "already_set"}})
          assert_empty AcceptDisagreements.call(label: "r1").data[:candidates]
        end

        test "a dry run changes nothing and lists candidates" do
          data = AcceptDisagreements.call(label: "r1").data
          assert_equal ["American"], @book.reload.countries.map(&:name)
          assert_equal [0, "British", ["American"]], [data[:accepted], data[:candidates].sole[:proposed], data[:candidates].sole[:held]]
        end

        test "enrichment_ids narrows the candidates" do
          assert_empty AcceptDisagreements.call(label: "r1", enrichment_ids: [@row.id + 1]).data[:candidates]
          assert_equal 1, AcceptDisagreements.call(label: "r1", enrichment_ids: [@row.id]).data[:candidates].size
        end
      end
    end
  end
end
