# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class AuthorProfileTest < ActiveSupport::TestCase
        test "names are the name then the alternate names, squished, without blanks" do
          author = ::Books::Author.new(name: "Leo  Tolstoy", alternate_names: ["Lev Tolstoy", " "])

          assert_equal ["Leo Tolstoy", "Lev Tolstoy"], AuthorProfile.new(author).names
        end

        test "titles come ranked first, each followed by its alternate titles" do
          author = ::Books::Author.create!(name: "Profile Author")
          unranked = ::Books::Book.create!(title: "Unranked Book")
          ranked = ::Books::Book.create!(title: "Ranked Book", alternate_titles: ["Ranked Alt"])
          author.book_authors.create!(book: unranked, position: 1)
          author.book_authors.create!(book: ranked, position: 2)
          RankedItem.create!(item: ranked, ranking_configuration: ranking_configurations(:books_global), rank: 1)

          assert_equal ["Ranked Book", "Ranked Alt", "Unranked Book"], AuthorProfile.new(author).titles
        end

        test "the line names the author, alternates, years, titles and countries" do
          line = AuthorProfile.new(books_authors(:tolstoy)).line

          assert_equal "Leo Tolstoy | also known as Lev Tolstoy, Lev Nikolayevich Tolstoy | 1828–1910 | wrote: War and Peace; Voyna i mir",
            line.split(" | countries: ").first
        end

        test "a lifespan shows an unknown birth as a question mark and a living author open-ended" do
          assert_equal ["?–1910", "1991–"], [AuthorProfile.lifespan(nil, 1910), AuthorProfile.lifespan(1991, nil)]
          assert_nil AuthorProfile.lifespan(nil, nil)
        end

        test "ranked books are title and first published year, ranked first, up to the limit" do
          author = ::Books::Author.create!(name: "Profile Author")
          unranked = ::Books::Book.create!(title: "Unranked Book", first_published_year: 2001)
          ranked = ::Books::Book.create!(title: "Ranked Book")
          author.book_authors.create!(book: unranked, position: 1)
          author.book_authors.create!(book: ranked, position: 2)
          RankedItem.create!(item: ranked, ranking_configuration: ranking_configurations(:books_global), rank: 1)
          profile = AuthorProfile.new(author)

          assert_equal [["Ranked Book", nil], ["Unranked Book", 2001]], profile.ranked_books(10)
          assert_equal [["Ranked Book", nil]], profile.ranked_books(1)
        end
      end
    end
  end
end
