# frozen_string_literal: true

require "test_helper"

module Books
  module Goodreads
    class AgreementTest < ActiveSupport::TestCase
      # authors: [name, role] pairs, the first credited as primary.
      def page(title: "War and Peace", authors: [["Leo Tolstoy", "Author"], ["Aylmer Maude", "Translator"]], outcome: :found)
        ::Books::GoodreadsPage.new(goodreads_book_id: 656, outcome: outcome, fetched_at: Time.current, title: title,
          authors: authors.each_with_index.map { |(name, role), index| {"name" => name, "role" => role, "primary" => index.zero?} })
      end

      def verdict(title: "War and Peace", primary_author: "Leo Tolstoy", page: self.page)
        result = Agreement.call(edition: ::Books::GoodreadsEdition.new(title: title, primary_author: primary_author), page: page)
        [result.outcome, result.author_names]
      end

      test "the same book agrees, and only its creators become authors" do
        assert_equal [:verified, ["Leo Tolstoy"]], verdict
      end

      test "a fuller name on Goodreads still agrees, and the page's spelling is used" do
        quixote = page(title: "Don Quixote", authors: [["Miguel de Cervantes Saavedra", "Author"]])

        assert_equal [:verified, ["Miguel de Cervantes Saavedra"]],
          verdict(title: "Don Quixote", primary_author: "Miguel de Cervantes", page: quixote)
      end

      test "a subtitle, a series suffix, case, punctuation and a full-width colon are no difference" do
        pairs = [
          ["The Great Wall", "The Great Wall: China Against the World, 1000 BC - AD 2000"],
          ["The Corpse In Oozak's Pond", "The Corpse in Oozak's Pond (Peter Shandy #6"],
          ["沙海:荒沙诡影", "沙海：荒沙诡影"],
          ["The Mysterious Disappearance Of Leon", "The Mysterious Disappearance of Leon"]
        ]

        pairs.each do |mine, theirs|
          assert_equal :verified, verdict(title: mine, page: page(title: theirs)).first, "#{mine} vs #{theirs}"
        end
      end

      test "a real Goodreads id under an invented title is a mismatch" do
        assert_equal [:mismatch, []], verdict(title: "War and Peace and Zombies")
      end

      test "the right title under another author is a mismatch" do
        assert_equal [:mismatch, []], verdict(primary_author: "Fyodor Dostoevsky")
      end

      test "a translator's name does not back the edition" do
        assert_equal [:mismatch, []], verdict(primary_author: "Aylmer Maude")
      end

      test "a page with no roles agrees on any name it lists, and only that name becomes the author" do
        legacy = ::Books::GoodreadsPage.new(goodreads_book_id: 335131, outcome: :found, fetched_at: Time.current, title: "The Vile Village",
          authors: [{"name" => "Brett Helquist", "role" => nil, "primary" => false}, {"name" => "Lemony Snicket", "role" => nil, "primary" => false}])

        assert_equal [:verified, ["Lemony Snicket"]], verdict(title: "The Vile Village", primary_author: "Lemony Snicket", page: legacy)
      end

      test "an anthology's editor, credited first, agrees; a contributor inside it does not" do
        anthology = page(title: "The Best American Short Stories 2010", authors: [["Richard Russo", "Editor"], ["Alice Munro", "Contributor"]])

        assert_equal [:verified, ["Richard Russo"]], verdict(title: "The Best American Short Stories 2010", primary_author: "Richard Russo", page: anthology)
        assert_equal :mismatch, verdict(title: "The Best American Short Stories 2010", primary_author: "Alice Munro", page: anthology).first
      end

      test "a comic's writers are its authors" do
        comic = page(title: "Batman, Volume 8: Superheavy",
          authors: [["Scott Snyder", "Writer"], ["Brian Azzarello", "Writer"], ["Greg Capullo", "Illustrator"]])

        assert_equal [:verified, ["Scott Snyder", "Brian Azzarello"]],
          verdict(title: "Batman, Volume 8: Superheavy", primary_author: "Scott Snyder", page: comic)
      end

      test "a not-found page says so" do
        assert_equal [:not_found, []], verdict(page: page(outcome: :not_found, title: nil, authors: []))
      end

      test "a blocked page is no answer" do
        assert_raises(ArgumentError) { verdict(page: page(outcome: :blocked)) }
      end
    end
  end
end
