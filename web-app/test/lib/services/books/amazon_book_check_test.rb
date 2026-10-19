# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    class AmazonBookCheckTest < ActiveSupport::TestCase
      # Creators API shape; every contributor gets `role` (default "Author").
      def product(title:, binding: "Paperback", date: "2008-10-14T00:00:01Z", authors: ["Leo Tolstoy"], roles: nil)
        role = Array(roles).first || "Author"
        {
          "asin" => "1400079985",
          "itemInfo" => {
            "title" => {"displayValue" => title},
            "byLineInfo" => {"contributors" => authors.map { |name| {"name" => name, "role" => role} }},
            "classifications" => {"binding" => {"displayValue" => binding}},
            "contentInfo" => {"publicationDate" => {"displayValue" => date}}
          }
        }
      end

      test "split_title strips packaging and splits on the first colon" do
        assert_equal ["War and Peace", "A Novel"], AmazonBookCheck.split_title("War and Peace: A Novel (Vintage Classics) [Paperback]")
        assert_equal [nil, nil], AmazonBookCheck.split_title(nil)
      end

      test "set? is true for a set word in brackets, a set subtitle, a set head title, or a box binding" do
        book = books_books(:war_and_peace)
        assert AmazonBookCheck.set?(book, product(title: "War and Peace (Boxed Set)"))
        assert AmazonBookCheck.set?(book, product(title: "War and Peace (4-Book Boxed Set)"))
        assert AmazonBookCheck.set?(book, product(title: "War and Peace: Books 1-3"))
        assert AmazonBookCheck.set?(book, product(title: "The Tolstoy Collection"))
        assert AmazonBookCheck.set?(book, product(title: "War and Peace", binding: "Boxed Set"))
      end

      test "set? is false for a single-book series marker and a plain edition" do
        book = books_books(:war_and_peace)
        refute AmazonBookCheck.set?(book, product(title: "War and Peace (Tolstoy Trilogy, Book 1)"))
        refute AmazonBookCheck.set?(book, product(title: "War and Peace (Vintage Classics)"))
        refute AmazonBookCheck.set?(book, product(title: "War and Peace (Tolstoy Trilogy #1)"))
        assert AmazonBookCheck.set?(book, product(title: "War and Peace (Book 1-3)"))
      end

      test "set? ignores a set word the book's own title carries" do
        book = ::Books::Book.create!(title: "Collection of Sand")
        refute AmazonBookCheck.set?(book, product(title: "Collection of Sand: Essays (Penguin Modern Classics)"))
        assert AmazonBookCheck.set?(book, product(title: "Collection of Sand (Boxed Set)"))
      end

      test "set? ignores a set word an alternate title carries" do
        book = ::Books::Book.create!(title: "Sand", alternate_titles: ["Collection of Sand"])
        refute AmazonBookCheck.set?(book, product(title: "Collection of Sand: Essays"))
      end

      test "same_book? accepts an exact title, a dropped subtitle and an alternate title" do
        book = books_books(:war_and_peace)
        assert AmazonBookCheck.same_book?(book, product(title: "War and Peace (Vintage Classics)"))
        assert AmazonBookCheck.same_book?(book, product(title: "War and Peace: A Novel"))
        book.update!(alternate_titles: ["Voina i mir"])
        assert AmazonBookCheck.same_book?(book, product(title: "Voina i mir"))
      end

      test "same_book? rejects a set, another title, an earlier year, another author, or no author" do
        book = books_books(:war_and_peace)
        refute AmazonBookCheck.same_book?(book, product(title: "War and Peace (Boxed Set)"))
        refute AmazonBookCheck.same_book?(book, product(title: "Anna Karenina"))
        refute AmazonBookCheck.same_book?(book, product(title: "War and Peace", date: "1801-01-01"))
        refute AmazonBookCheck.same_book?(book, product(title: "War and Peace", authors: ["Someone Else"]))
        refute AmazonBookCheck.same_book?(book, product(title: "War and Peace", authors: []))
      end

      test "same_book? ignores contributors who are not authors" do
        book = books_books(:war_and_peace)
        translator_only = product(title: "War and Peace", authors: ["Leo Tolstoy"], roles: ["Translator"])
        refute AmazonBookCheck.same_book?(book, translator_only)
        assert_equal [], AmazonBookCheck.author_names(translator_only)
      end

      test "set? counts a box set or omnibus hiding inside a single-book marker bracket" do
        book = books_books(:war_and_peace)
        hunger = ::Books::Book.create!(title: "The Hunger Games")
        assert AmazonBookCheck.set?(hunger, product(title: "The Hunger Games (Item #12345, Box Set)"))
        assert AmazonBookCheck.set?(hunger, product(title: "The Hunger Games (Book 1, Omnibus)"))
        refute AmazonBookCheck.set?(book, product(title: "War and Peace (Tolstoy Trilogy, Book 1)"))
      end

      test "set? accepts a bare trailing number or a spelled-out number as a single-book marker" do
        shadow = ::Books::Book.create!(title: "Shadow and Bone")
        hunger = ::Books::Book.create!(title: "The Hunger Games")
        refute AmazonBookCheck.set?(shadow, product(title: "Shadow and Bone (The Shadow and Bone Trilogy, 1)"))
        refute AmazonBookCheck.set?(hunger, product(title: "The Hunger Games (Hunger Games Trilogy, Book One)"))
        assert AmazonBookCheck.set?(shadow, product(title: "Shadow and Bone (The Shadow and Bone Trilogy, 1-3)"))
        assert AmazonBookCheck.set?(shadow, product(title: "Shadow and Bone (The Shadow and Bone Trilogy)"))
      end

      test "set? counts a #N-M range anywhere in the title" do
        dune = ::Books::Book.create!(title: "Dune")
        assert AmazonBookCheck.set?(dune, product(title: "Dune (Dune Chronicles, #1-3)"))
        refute AmazonBookCheck.set?(dune, product(title: "Dune (Dune Chronicles, #1)"))
      end

      test "derivative? and same_book? reject adaptations and study aids of the book" do
        {
          "Kindred" => "Kindred: A Graphic Novel Adaptation",
          "The Handmaid's Tale" => "The Handmaid's Tale (Graphic Novel)",
          "Dune" => "Dune: The Graphic Novel, Book 1: Dune",
          "Unbroken" => "Unbroken (The Young Adult Adaptation): An Olympian's Journey",
          "Les Misérables" => "Les Misérables (Abridged)",
          "Outlander" => "Outlander: The Official Outlander Coloring Book"
        }.each do |own, listing|
          book = ::Books::Book.create!(title: own)
          ::Books::BookAuthor.create!(book: book, author: books_authors(:tolstoy), position: 1)
          assert AmazonBookCheck.derivative?(book, product(title: listing)), listing
          refute AmazonBookCheck.same_book?(book, product(title: listing)), listing
        end
      end

      test "derivative? is false for a term the book's own title carries and for a plain edition" do
        maus = ::Books::Book.create!(title: "Maus: A Graphic Novel")
        ::Books::BookAuthor.create!(book: maus, author: books_authors(:tolstoy), position: 1)
        refute AmazonBookCheck.derivative?(maus, product(title: "Maus: A Graphic Novel (Pantheon)"))
        assert AmazonBookCheck.same_book?(maus, product(title: "Maus: A Graphic Novel (Pantheon)"))
        refute AmazonBookCheck.derivative?(books_books(:war_and_peace), product(title: "War and Peace (Vintage Classics)"))
      end

      test "a missing or bracket-only title never raises" do
        book = books_books(:war_and_peace)
        untitled = product(title: nil)
        refute AmazonBookCheck.same_book?(book, untitled)
        refute AmazonBookCheck.set?(book, untitled)
        assert AmazonBookCheck.set?(book, product(title: "(Boxed Set)"))
      end
    end
  end
end
