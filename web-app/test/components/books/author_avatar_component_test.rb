# frozen_string_literal: true

require "test_helper"

module Books
  class AuthorAvatarComponentTest < ViewComponent::TestCase
    def initials_for(name)
      author = Books::Author.new(name: name)
      Books::AuthorAvatarComponent.new(author: author).send(:initials)
    end

    test "uses the first and last token" do
      assert_equal "FD", initials_for("Fyodor Dostoevsky")
    end

    test "skips particles because they sit mid-name" do
      assert_equal "PL", initials_for("Pierre Choderlos de Laclos")
      assert_equal "JG", initials_for("Johann Wolfgang von Goethe")
    end

    test "handles dotted initials" do
      assert_equal "WB", initials_for("W. E. B. Du Bois")
      assert_equal "FF", initials_for("F. Scott Fitzgerald")
    end

    test "handles single-token names" do
      assert_equal "H", initials_for("Homer")
      assert_equal "S", initials_for("Stendhal")
    end

    test "handles non-ASCII names" do
      assert_equal "EB", initials_for("Emily Brontë")
      assert_equal "GM", initials_for("Gabriel García Márquez")
      assert_equal "AD", initials_for("Alfred Döblin")
    end

    test "never exceeds two characters" do
      assert_equal 2, initials_for("Jalal al-Din Muhammad Rumi").length
    end

    test "renders the monogram when no image is attached" do
      render_inline(Books::AuthorAvatarComponent.new(author: books_authors(:tolstoy)))

      assert_selector "[aria-hidden='true']", text: "LT"
      assert_no_selector "img"
    end
  end
end
