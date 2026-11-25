# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Books
    module Book
      class TitleFormsTest < ActiveSupport::TestCase
        test "split cuts at the first colon outside brackets" do
          assert_equal ["Andrew Johnson", "A Biography"], TitleForms.split("Andrew Johnson: A Biography")
          assert_equal ["Spider-Man", "Hunt: Part Two"], TitleForms.split("Spider-Man: Hunt: Part Two")
          assert_equal ["Dune", nil], TitleForms.split("Dune")
        end

        test "split never cuts inside brackets" do
          assert_equal ["Accounting 2 (Quick Study: Business)", nil], TitleForms.split("Accounting 2 (Quick Study: Business)")
          assert_equal ["マギ 18 [Magi: Sinbad no Bouken 18]", nil], TitleForms.split("マギ 18 [Magi: Sinbad no Bouken 18]")
          assert_equal ["Goblin Market (Dover: Poetry)", "A Selection"], TitleForms.split("Goblin Market (Dover: Poetry): A Selection")
        end

        test "split leaves a colon with no space after it, or nothing on one side of it" do
          assert_equal ["The 12:30 from Croydon", nil], TitleForms.split("The 12:30 from Croydon")
          assert_equal [": A Memoir", nil], TitleForms.split(": A Memoir")
          assert_equal ["Open:", nil], TitleForms.split("Open:")
          assert_equal [nil, nil], TitleForms.split(nil)
        end

        test "split keeps reading when a bracket never closes" do
          assert_equal ["Smile :( and Other Stories: Poems", nil], TitleForms.split("Smile :( and Other Stories: Poems")
        end

        test "without_note drops a closing series note that names its series and one number" do
          {
            "BOOM goes the Bride (Brides of Nap City Book 1)" => "BOOM goes the Bride",
            "The History of Manners (The Civilizing Process, Vol. 1)" => "The History of Manners",
            "Theology: The New Covenant (The Glory of the Lord: A Theological Aesthetics, Vol. 7)" => "Theology: The New Covenant",
            "Okomi Plays in the Leaves (The Okomi Series, 3)" => "Okomi Plays in the Leaves",
            "A Hora Mais Sombria (A Mediadora, Livro 4)" => "A Hora Mais Sombria",
            "The Way Out (The Maze, Book Two)" => "The Way Out"
          }.each { |given, expected| assert_equal expected, TitleForms.without_note(given), given }
        end

        test "without_note drops a closing language or format tag" do
          assert_equal "Enrique IV (Teatro)", TitleForms.without_note("Enrique IV (Teatro) (Spanish Edition)")
          assert_equal "Dune", TitleForms.without_note("Dune (Kindle Edition)")
          assert_equal "Dune", TitleForms.without_note("Dune (mobi)")
        end

        test "without_note keeps a bracket that may say which book this is" do
          ["Theology (Volume 2)", "Poems (Vol. 2)", "The Time Machine (Graphic Novel)", "Night (Box Set, Book 1)",
            "Watership Down (The Graphic Novel Series, Book 1)", "The World of Tiers (World of Tiers Omnibus 3-5)",
            "Arkane (Arkane Books 1-3)", "The Iliad (Classics Illustrated)", "Player's Handbook (Dungeons & Dragons, 3rd Edition)",
            "Dikter (1916)", "Theology (Volume 2, Book 1)", "Paris Notebooks (Paris, 1920)", "Accounting 2 (Quick Study: Business)",
            "How to Work with (Almost) Anyone"].each do |title|
            assert_equal title, TitleForms.without_note(title), title
          end
        end

        test "without_note keeps a series note whose series has the book's own title" do
          assert_equal "Rom: The Marvel Years (Rom, 1)", TitleForms.without_note("Rom: The Marvel Years (Rom, 1)")
          assert_equal "Homicide (Homicide, Book 1)", TitleForms.without_note("Homicide (Homicide, Book 1)")
        end

        test "without_note never leaves an empty title" do
          assert_equal "(The Maze, Book 2)", TitleForms.without_note("(The Maze, Book 2)")
        end

        test "main drops every closing bracket and the subtitle" do
          assert_equal "The Iliad", TitleForms.main("The Iliad (Classics Illustrated)")
          assert_equal "Accounting 2", TitleForms.main("Accounting 2 (Quick Study: Business)")
          assert_equal "William Morris", TitleForms.main("William Morris: Artist, Writer (Cambridge Library Collection) (Volume 2)")
          assert_equal "(The Maze)", TitleForms.main("(The Maze)")
        end

        test "full joins a title and its subtitle" do
          assert_equal "Andrew Johnson: A Biography", TitleForms.full("Andrew Johnson", "A Biography")
          assert_equal "Dune", TitleForms.full("Dune", "")
        end
      end
    end
  end
end
