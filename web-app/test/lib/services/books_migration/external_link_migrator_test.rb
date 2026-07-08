require "test_helper"

module Services
  module BooksMigration
    class ExternalLinkMigratorTest < ActiveSupport::TestCase
      setup do
        @book = Books::Book.create!(title: "Link Parent")
        @user = users(:regular_user)
      end

      def run_migrator(rows)
        migrator = ExternalLinkMigrator.new
        migrator.stubs(:legacy_each).multiple_yields(*rows.zip)
        migrator.call
      end

      def legacy_row(overrides = {})
        {
          "id" => 1,
          "name" => "Wikipedia",
          "url" => "http://en.wikipedia.org/wiki/Test",
          "user_id" => @user.id,
          "description" => nil,
          "book_id" => @book.id,
          "created_at" => Time.utc(2022, 11, 5, 4, 12, 17),
          "updated_at" => Time.utc(2022, 11, 5, 4, 12, 17)
        }.merge(overrides)
      end

      test "maps a legacy link to a Books::Book-parented ExternalLink" do
        result = run_migrator([legacy_row])

        assert result[:success], result[:error]
        assert_equal 1, result[:data][:count]
        assert_equal "ExternalLink", result[:data][:model]

        link = ExternalLink.find_by(parent_type: "Books::Book", parent_id: @book.id)
        assert_not_nil link
        assert_equal @book, link.parent
        assert_equal @user, link.submitted_by
        assert_equal "Wikipedia", link.name
        assert_nil link.description
        assert_equal "http://en.wikipedia.org/wiki/Test", link.url
        assert link.public?
        assert link.link_category_information?
        assert link.source_wikipedia?
        assert_nil link.source_name
      end

      test "preserves legacy created_at/updated_at" do
        ts = Time.utc(2024, 12, 15, 9, 0, 0)
        run_migrator([legacy_row("created_at" => ts, "updated_at" => ts)])

        link = ExternalLink.find_by(parent_type: "Books::Book", parent_id: @book.id)
        assert_equal ts, link.created_at
        assert_equal ts, link.updated_at
      end

      test "infers source from the URL host" do
        cases = {
          "http://en.wikipedia.org/wiki/A" => "wikipedia",
          "http://de.wikipedia.org/wiki/B" => "wikipedia",
          "https://www.goodreads.com/book/show/1" => "goodreads",
          "http://www.amazon.com/dp/123" => "amazon",
          "https://bookshop.org/books/x" => "bookshop_org",
          "http://books.google.com/books?q=x" => "other",
          "http://www.time.com/x" => "other",
          "http://www.powells.com/biblio/x" => "other"
        }
        rows = cases.keys.each_with_index.map do |url, i|
          book = Books::Book.create!(title: "Src Parent #{i}")
          legacy_row("id" => 100 + i, "book_id" => book.id, "url" => url)
        end
        result = run_migrator(rows)

        assert result[:success], result[:error]
        cases.each do |url, expected|
          link = ExternalLink.find_by(url: url)
          assert_not_nil link, "no link for #{url}"
          assert_equal expected, link.source, "wrong source for #{url}"
        end
      end

      test "sets source_name to the host for other-source links only" do
        other_book = Books::Book.create!(title: "Other Parent")
        run_migrator([
          legacy_row("id" => 200, "book_id" => other_book.id, "url" => "http://books.google.com/books?q=x"),
          legacy_row("id" => 201, "url" => "http://en.wikipedia.org/wiki/Y")
        ])

        other = ExternalLink.find_by(url: "http://books.google.com/books?q=x")
        assert other.source_other?
        assert_equal "books.google.com", other.source_name

        wiki = ExternalLink.find_by(url: "http://en.wikipedia.org/wiki/Y")
        assert wiki.source_wikipedia?
        assert_nil wiki.source_name
      end

      test "classifies non-ASCII wikipedia URLs without raising" do
        url = "http://en.wikipedia.org/wiki/Gödel,_Escher,_Bach"
        result = run_migrator([legacy_row("url" => url)])

        assert result[:success], result[:error]
        assert ExternalLink.find_by(url: url).source_wikipedia?
      end

      test "normalizes scheme-less URLs to https" do
        result = run_migrator([legacy_row("url" => "en.wikipedia.org/wiki/The_Hunting_of_the_Snark")])

        assert result[:success], result[:error]
        link = ExternalLink.find_by(parent_type: "Books::Book", parent_id: @book.id)
        assert_equal "https://en.wikipedia.org/wiki/The_Hunting_of_the_Snark", link.url
        assert link.source_wikipedia?
      end

      test "is idempotent on [parent, url]: re-running does not duplicate" do
        run_migrator([legacy_row])

        assert_no_difference -> { ExternalLink.count } do
          result = run_migrator([legacy_row])
          assert result[:success], result[:error]
          assert_equal 1, result[:data][:count]
        end
      end

      test "fails loud naming the legacy id when the book is missing" do
        missing = Books::Book.maximum(:id).to_i + 999_999
        result = run_migrator([legacy_row("id" => 4242, "book_id" => missing)])

        refute result[:success]
        assert_match(/4242/, result[:error])
      end
    end
  end
end
