# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsRebuild
      class CompareIdentityTest < ActiveSupport::TestCase
        def book(title, author = nil)
          ::Books::Book.create!(title: title).tap do |book|
            book.book_authors.create!(author: ::Books::Author.create!(name: author), position: 1) if author
          end
        end

        def edition(id, title, author, year: 2000)
          ::Books::GoodreadsEdition.new(id: id, title: title, primary_author: author, original_publication_year: year,
            goodreads_book_id: id, additional_authors: [])
        end

        def compare(book, *editions_in_groups)
          editions = editions_in_groups.flatten
          groups = editions_in_groups.map { |members| {"edition_ids" => members.map(&:id)} }
          CompareIdentity.call(book: book, groups: groups, editions_by_id: editions.index_by(&:id))
        end

        test "matching title and author agree" do
          result = compare(book("The Remains of the Day", "Kazuo Ishiguro"), [edition(1, "The Remains of the Day", "Kazuo Ishiguro")])

          assert_equal({title_agrees: true, authors_agree: true, wrong_book: false}, result)
        end

        test "a stripped title disagrees but is not the wrong book" do
          result = compare(book("X Men", "Chris Claremont"), [edition(1, "X-Men: The Age of Apocalypse, Vol. 2", "Chris Claremont")])

          assert_equal({title_agrees: false, authors_agree: true, wrong_book: false}, result)
        end

        test "a wrong author" do
          result = compare(book("The Eyes of Darkness", "Beverley Nichols"), [edition(1, "The Eyes of Darkness", "Dean Koontz")])

          assert_equal({title_agrees: true, authors_agree: false, wrong_book: false}, result)
        end

        test "the wrong book" do
          result = compare(book("Hothouse", "Brian W. Aldiss"), [edition(1, "The Hidden Harbor Mystery", "Franklin W. Dixon")])

          assert result[:wrong_book]
        end

        test "a lump whose minor group matches is not the wrong book" do
          result = compare(book("Hothouse", "Brian W. Aldiss"),
            [edition(1, "The Hidden Harbor Mystery", "Franklin W. Dixon")], [edition(2, "Hothouse", "Brian W. Aldiss", year: 1962)])

          assert_equal({title_agrees: false, authors_agree: false, wrong_book: false}, result)
        end

        test "a translation in the main group lets the title agree" do
          result = compare(book("Tenth of December", "George Saunders"),
            [edition(1, "Dez de Dezembro", "George Saunders"), edition(2, "Tenth of December", "George Saunders")])

          assert result[:title_agrees]
        end

        # Found on the first full dev run: our title held a subtitle the export
        # lacks, and "title disagrees" was reported though nothing was stripped.
        test "a subtitle we hold that the export lacks still agrees" do
          ours = book("The Food Bible", "Judith Wills")
          ours.update!(subtitle: "Everything You Need to Know")

          assert compare(ours, [edition(1, "The Food Bible", "Judith Wills")])[:title_agrees]
        end

        # Also from the first dev run: a subtitle only the export has made the
        # loose check fail, so a same-title book with a wrong author was called
        # the wrong book.
        test "a subtitle only the export has is a stripped title, not the wrong book" do
          result = compare(book("An Unexpected Cookbook", "James Oseland"),
            [edition(1, "An Unexpected Cookbook: The Unofficial Book of Hobbit Cookery", "Chris-Rachael Oseland")])

          assert_equal({title_agrees: false, authors_agree: false, wrong_book: false}, result)
        end

        # Legacy's titleize split run-together words ("JoJo's" to "Jo Jo's"):
        # the right book with a mangled title and a wrong author, not another book.
        test "a title legacy split apart is still the same book" do
          result = compare(book("Jo Jo's Bizarre Adventure", "Nobuyoshi Araki"),
            [edition(1, "JoJo's Bizarre Adventure: Part 4—Diamond Is Unbreakable, Vol. 7", "Hirohiko Araki")])

          assert_equal({title_agrees: false, authors_agree: false, wrong_book: false}, result)
        end

        test "a book with no authors does not agree on authors" do
          result = compare(book("Hothouse"), [edition(1, "Hothouse", "Brian W. Aldiss")])

          assert_equal false, result[:authors_agree]
          refute result[:wrong_book]
        end

        test "no groups" do
          result = CompareIdentity.call(book: book("Orphan"), groups: [], editions_by_id: {})

          assert_equal [nil, nil, false], result.values_at(:title_agrees, :authors_agree, :wrong_book)
        end
      end
    end
  end
end
