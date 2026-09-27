# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Books
    module Author
      module Providers
        class OpenLibraryTest < ActiveSupport::TestCase
          BASE_URL = "http://open-library.test:8080"

          def setup
            @client = ::Books::OpenLibrary::Client.new(
              config: ::Books::OpenLibrary::Configuration.new(base_url: BASE_URL),
              breaker: ::Books::OpenLibrary::CircuitBreaker.new(
                key: "test:author_provider:open_library", failure_threshold: 5, cooldown: 60,
                redis: ::Books::OpenLibrary::FakeRedis.new
              )
            )
            @provider = Providers::OpenLibrary.new(client: @client)
          end

          def ol_author(key: "OL26783A", name: "Leo Tolstoy", alternate_names: ["Lev Nikolayevich Tolstoy", "Leo Tolstoï"], birth_year: 1828, death_year: 1910)
            ::Books::OpenLibrary::Author.new(key: key, source: "openlibrary", name: name, alternate_names: alternate_names,
              birth_year: birth_year, death_year: death_year, redirected_from: [], source_version: nil)
          end

          def stub_author(key, status: 200)
            body = {"source_version" => nil, "data" => {"key" => {"source" => "openlibrary", "key" => key}, "redirected_from" => [],
                                                        "name" => "Leo Tolstoy", "alternate_names" => [], "birth_year" => 1828, "death_year" => 1910}}
            stub_request(:get, "#{BASE_URL}/authors/#{key}").to_return(status: status, body: (status == 200) ? body.to_json : "{}")
          end

          def match_with(record)
            DataImporters::Match.new(outcome: :unmatched, confidence: :high, decided_by: :rule,
              external: DataImporters::Candidate.new(external_key: record.key, external_source: :open_library, external_record: record))
          end

          test "fills blank years, unions alternate names and stamps the key, reusing match.external without a request" do
            author = ::Books::Author.new(name: "Lev Tolstoy")

            result = @provider.populate(author, query: ImportQuery.new(name: "Lev Tolstoy", open_library_author_key: "OL26783A"), match: match_with(ol_author))

            assert result.success?
            assert_equal %w[birth_year death_year alternate_names], result.data_populated
            assert_equal [1828, 1910], [author.birth_year, author.death_year]
            assert_equal ["Leo Tolstoy", "Lev Nikolayevich Tolstoy", "Leo Tolstoï"], author.alternate_names
            assert_equal ["OL26783A"], author.identifiers.select { |i| i.identifier_type == "books_author_openlibrary_id" }.map(&:value)
            assert_not_requested(:get, %r{#{BASE_URL}/authors/}o)
          end

          test "never overwrites a populated name or year, and skips alternate names it already holds" do
            author = books_authors(:tolstoy)
            author.update!(birth_year: 1827)

            result = @provider.populate(author, query: ImportQuery.new(name: "Leo Tolstoy"), match: match_with(ol_author(alternate_names: ["LEV TOLSTOY"])))

            assert_equal [], result.data_populated
            assert_equal ["Leo Tolstoy", 1827, 1910], [author.name, author.birth_year, author.death_year]
          end

          test "writes the name only when it is blank (a key-only import)" do
            author = ::Books::Author.new

            result = @provider.populate(author, query: ImportQuery.new(open_library_author_key: "OL26783A"), match: match_with(ol_author))

            assert_equal "Leo Tolstoy", author.name
            assert_includes result.data_populated, "name"
          end

          test "fetches by the query key when the match carries no Open Library record" do
            stub_author("OL26783A")
            author = ::Books::Author.new(name: "Leo Tolstoy")

            assert @provider.populate(author, query: ImportQuery.new(name: "Leo Tolstoy", open_library_author_key: "OL26783A"), match: nil).success?
            assert_requested(:get, "#{BASE_URL}/authors/OL26783A", times: 1)
          end

          test "an item-based run fetches by the author's held key" do
            author = books_authors(:tolstoy)
            author.identifiers.create!(identifier_type: :books_author_openlibrary_id, value: "OL26783A")
            stub_author("OL26783A")

            assert @provider.populate(author, query: nil, match: nil).success?
            assert_requested(:get, "#{BASE_URL}/authors/OL26783A", times: 1)
          end

          test "an author with no key has nothing to look up: success with nothing populated and no request" do
            result = @provider.populate(::Books::Author.new(name: "Nobody Anybody"), query: ImportQuery.new(name: "Nobody Anybody"), match: nil)

            assert result.success?
            assert_equal [], result.data_populated
            assert_not_requested(:get, %r{#{BASE_URL}/authors/}o)
          end

          test "a service error is a failure result, never an exception" do
            stub_author("OL26783A", status: 500)

            result = @provider.populate(::Books::Author.new(name: "Leo Tolstoy"), query: ImportQuery.new(name: "Leo Tolstoy", open_library_author_key: "OL26783A"), match: nil)

            assert_not result.success?
            assert_match(/Open Library ServerError/, result.errors.first)
          end
        end
      end
    end
  end
end
