# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class MergeUnknownTest < ActiveSupport::TestCase
        setup do
          @unknown = books_authors(:excluded_placeholder)
          @anonymous = ::Books::Author.create!(name: "Anonymous")
          @book = books_books(:combo_steinbeck)
          ::Books::BookAuthor.create!(book: @book, author: @anonymous, position: 1)
          @anonymous.descriptions.create!(content: "Anonymous is a placeholder name used when the author is unknown.", kind: :summary, locale: "en", source: :ai_generated)
        end

        test "a dry run lists the authors it would merge and changes nothing" do
          result = MergeUnknown.call(apply: false)

          assert result.success?
          assert_equal @unknown.id, result.data[:target_id]
          assert_equal [{id: @anonymous.id, name: "Anonymous", books: 1}], result.data[:sources]
          assert_equal 0, result.data[:merged]
          assert ::Books::Author.exists?(@anonymous.id)
        end

        test "apply merges every placeholder into the canonical Unknown and drops the descriptions they brought" do
          ::Services::RankingConfigurations::RequestRefresh.stubs(:call)
          before = @unknown.descriptions.count

          result = MergeUnknown.call(apply: true)

          assert result.success?
          assert_equal 1, result.data[:merged]
          assert_empty result.data[:failed]
          assert_not ::Books::Author.exists?(@anonymous.id)
          assert_includes @book.reload.authors, @unknown
          assert_equal before, @unknown.reload.descriptions.count
        end

        test "apply asks for one author ranking refresh, not one per merge" do
          ::Books::Author.create!(name: "unknown author")
          authors_config = ::Books::Authors::RankingConfiguration.default_primary
          if authors_config
            ::Services::RankingConfigurations::RequestRefresh.expects(:call).with(config: authors_config, delay: 5.minutes).once
          else
            ::Services::RankingConfigurations::RequestRefresh.expects(:call).never
          end

          assert_equal 2, MergeUnknown.call(apply: true).data[:merged]
        end

        test "a rerun with nothing left to merge is a no-op" do
          ::Services::RankingConfigurations::RequestRefresh.stubs(:call)
          MergeUnknown.call(apply: true)

          ::Services::RankingConfigurations::RequestRefresh.expects(:call).never
          result = MergeUnknown.call(apply: true)

          assert result.success?
          assert_empty result.data[:sources]
          assert_equal 0, result.data[:merged]
        end

        test "a failed merge is reported and the others still run" do
          ::Services::RankingConfigurations::RequestRefresh.stubs(:call)
          other = ::Books::Author.create!(name: "Anon")
          ::Books::Author::Merger.stubs(:call).with { |args| args[:source].id == @anonymous.id }
            .returns(::Books::Author::Merger::Result.new(success?: false, data: nil, errors: ["boom"]))
          ::Books::Author::Merger.stubs(:call).with { |args| args[:source].id == other.id }.returns(::Books::Author::Merger::Result.new(success?: true, data: @unknown, errors: []))

          result = MergeUnknown.call(apply: true)

          assert_equal 1, result.data[:merged]
          assert_equal [{id: @anonymous.id, errors: ["boom"]}], result.data[:failed]
          assert ::Books::Author.exists?(@anonymous.id)
          assert_equal 1, @anonymous.descriptions.count, "a failed merge must keep the source's descriptions"
        end

        test "fails when no author is named exactly Unknown" do
          @unknown.update_columns(name: "Unknown Author")
          @anonymous.destroy!

          result = MergeUnknown.call(apply: true)

          assert_not result.success?
          assert_match(/no author named "Unknown"/, result.errors.first)
        end
      end
    end
  end
end
