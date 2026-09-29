# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class ViafNamesTest < ActiveSupport::TestCase
        test "words are letters only, case and diacritics folded, in order; tokens are sorted" do
          assert_equal ["willingham", "stacy"], ViafNames.words("Willingham, Stacy, 1991-")
          assert_equal ["stacy", "willingham"], ViafNames.tokens("Willingham, Stacy, 1991-")
          assert_equal ["tolstoi", "leon"], ViafNames.words("Tolstoï, Léon")
        end

        test "a parenthesised fuller form is dropped" do
          assert_equal ["j", "r", "r", "tolkien"], ViafNames.tokens("Tolkien, J. R. R. (John Ronald Reuel)")
        end

        test "the same name in any order, with or without the comma or dates" do
          assert ViafNames.same?("Stacy Willingham", "Willingham, Stacy")
          assert ViafNames.same?("Stacy Willingham", "Willingham Stacy")
          assert ViafNames.same?("Stacy Willingham", "Stacy Willingham 1991–")
          assert ViafNames.same?("Gabriel Garcia Marquez", "García Márquez, Gabriel")
          assert_not ViafNames.same?("Stacy Willingham", "Stacy Willingham American writer")
          assert_not ViafNames.same?("Stacy Willingham", "Stacy Willinghamová")
          assert_not ViafNames.same?("", "")
        end

        test "a reordering has the same words as a name, in another order" do
          assert ViafNames.reordering?("Yan Mo", of: "Mo Yan")
          assert_not ViafNames.reordering?("Mo Yan", of: "Mo Yan")
          assert_not ViafNames.reordering?("Léon Tolstoï", of: "Leo Tolstoy")
        end

        test "an inverted heading reads in natural order; titles and later parts are dropped" do
          assert_equal "Stacy Willingham", ViafNames.natural("Willingham, Stacy")
          assert_equal "Leo Tolstoy", ViafNames.natural("Tolstoy, Leo, graf")
          assert_equal "J. R. R. Tolkien", ViafNames.natural("Tolkien, J. R. R. (John Ronald Reuel)")
          assert_equal "Stacy Willingham", ViafNames.natural("Willingham, Stacy, 1991-")
        end

        test "a peerage heading that repeats the surname inside the forenames is not duplicated" do
          assert_equal "George Gordon Byron", ViafNames.natural("Byron, George Gordon Byron, Baron")
          assert_equal "Thomas Babington Macaulay", ViafNames.natural("Macaulay, Thomas Babington Macaulay, Baron")
        end

        test "a heading without a comma has no reliable order" do
          assert_nil ViafNames.natural("Willingham Stacy")
          assert_nil ViafNames.natural("Homer")
          assert_nil ViafNames.natural(", Stacy")
        end

        test "Latin script only" do
          assert ViafNames.latin?("Léon Tolstoï")
          assert ViafNames.latin?("J. R. R. Tolkien")
          assert_not ViafNames.latin?("Лев Толстой")
          assert_not ViafNames.latin?("ウィリンガム, ステイシー")
          assert_not ViafNames.latin?("1991")
        end
      end
    end
  end
end
