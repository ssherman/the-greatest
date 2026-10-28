# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsRebuild
      class GroupEditionsTest < ActiveSupport::TestCase
        Evidence = Struct.new(:ol_work_keys)

        def edition(id, title:, author:, year:, volume: nil, gr: id)
          ::Books::GoodreadsEdition.new(id: id, title: title, primary_author: author, original_publication_year: year,
            series_number: volume, goodreads_book_id: gr, additional_authors: [])
        end

        def group(editions, rows: {}, evidence: {})
          GroupEditions.call(editions: editions, row_counts: editions.to_h { |e| [e.id, rows.fetch(e.id, 1)] }, evidence: evidence)
        end

        test "one work's editions are one group" do
          groups = group([edition(1, title: "Tenth of December", author: "George Saunders", year: 2013),
            edition(2, title: "Zehnter Dezember", author: "George Saunders", year: 2013)])

          assert_equal 1, groups.size
          assert_equal :coherent, GroupEditions.classify(groups)
        end

        test "initials spelled differently are one author" do
          groups = group([edition(1, title: "Nine Stories", author: "J.D. Salinger", year: 1953),
            edition(2, title: "Nine Stories", author: "J. D. Salinger", year: 1953)])

          assert_equal 1, groups.size
        end

        test "different original years are a lump, biggest group first" do
          groups = group([edition(1, title: "The Hidden Harbor Mystery", author: "Franklin W. Dixon", year: 1927),
            edition(2, title: "Hothouse", author: "Brian W. Aldiss", year: 1962)], rows: {1 => 1, 2 => 3})

          assert_equal :lump, GroupEditions.classify(groups)
          assert_equal [["Hothouse"], ["The Hidden Harbor Mystery"]], groups.map { |g| g["titles"] }
          assert_equal [3, 1], groups.map { |g| g["row_count"] }
        end

        test "numbered volumes by one author in one year are a lump" do
          groups = group([edition(1, title: "V for Vendetta", author: "Alan Moore", year: 1988, volume: "1"),
            edition(2, title: "V for Vendetta", author: "Alan Moore", year: 1988, volume: "2")])

          assert_equal 2, groups.size
        end

        test "a shared Open Library work joins a transliterated author" do
          editions = [edition(1, title: "War and Peace", author: "Leo Tolstoy", year: 1869),
            edition(2, title: "Voina i mir", author: "Lev Tolstoy", year: 1869)]
          shared = {1 => Evidence.new(["OL267933W"]), 2 => Evidence.new(["OL267933W"])}

          assert_equal 1, group(editions, evidence: shared).size
          assert_equal 2, group(editions).size
        end

        test "a shared Open Library work does not join different volumes" do
          editions = [edition(1, title: "Saga, Volume 1", author: "Brian K. Vaughan", year: 2012, volume: "1"),
            edition(2, title: "Saga, Volume 2", author: "Brian K. Vaughan", year: 2013, volume: "2")]
          shared = {1 => Evidence.new(["OL1W"]), 2 => Evidence.new(["OL1W"])}

          assert_equal 2, group(editions, evidence: shared).size
        end

        test "an edition with no year joins the matching group with the most rows" do
          editions = [edition(1, title: "A", author: "Jane Doe", year: 1950), edition(2, title: "B", author: "Jane Doe", year: 1960),
            edition(3, title: "A again", author: "Jane Doe", year: nil)]

          groups = group(editions, rows: {1 => 5, 2 => 2, 3 => 1})

          assert_equal 2, groups.size
          assert_equal [1, 3], groups.first["edition_ids"]
          assert_equal 6, groups.first["row_count"]
        end

        test "an edition matching no group starts its own" do
          groups = group([edition(1, title: "A", author: "Jane Doe", year: 1950),
            edition(2, title: "Z", author: "Someone Else", year: nil)])

          assert_equal 2, groups.size
        end

        test "classify with no groups is unsupported" do
          assert_equal :unsupported, GroupEditions.classify([])
        end

        test "group hash shape" do
          editions = (1..5).map { |i| edition(i, title: "Title #{i}", author: "Jane Doe", year: 2000, gr: 100 - i) }

          only = group(editions).first

          assert_equal %w[authors edition_ids goodreads_book_ids row_count titles volume year], only.keys.sort
          assert_equal 3, only["titles"].size
          assert_equal [95, 96, 97, 98, 99], only["goodreads_book_ids"]
          assert_equal ["Jane Doe"], only["authors"]
          assert_equal 2000, only["year"]
          assert_nil only["volume"]
        end
      end
    end
  end
end
