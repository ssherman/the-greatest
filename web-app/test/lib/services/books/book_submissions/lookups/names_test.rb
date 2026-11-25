require "test_helper"

module Services
  module Books
    module BookSubmissions
      module Lookups
        class NamesTest < ActiveSupport::TestCase
          # raw WorldCat creator => the author name, or nil when the shape is not one we are sure of
          PEOPLE = {
            # no comma: as it is, minus brackets, life dates and a closing period
            "Ursula K. Le Guin" => "Ursula K. Le Guin",
            "Homer" => "Homer",
            "Homer." => "Homer",
            "Mary Smith [Novelist]" => "Mary Smith",
            "Smith, John," => "John Smith",
            "Jennifer 8. Lee" => "Jennifer 8. Lee",
            "50 Cent" => "50 Cent",
            "Taizan5" => "Taizan5",
            "Exurb1a" => "Exurb1a",
            "タイザン5" => "タイザン5",
            "Mary Smith (Novelist)" => "Mary Smith",
            "Hemingway 1899-1961." => "Hemingway",
            "John Smith Jr." => "John Smith Jr.",
            "J.R.R. Tolkien" => "J.R.R. Tolkien",
            "Ursula K." => "Ursula K.",
            "Ursula Smith." => "Ursula Smith",
            # Last, First
            "Le Guin, Ursula K., 1929-2018." => "Ursula K. Le Guin",
            "King, Martin Luther, Jr., 1929-1968." => "Martin Luther King Jr.",
            "King, Martin Luther, 1929-1968, Jr." => "Martin Luther King Jr.",
            "Kurt Vonnegut, Jr." => "Kurt Vonnegut Jr.",
            "Hemingway, Ernest, 1899-" => "Ernest Hemingway",
            "Hemingway, Ernest 1899-1961." => "Ernest Hemingway",
            "Austen, Jane, 1775-1817 (Author)" => "Jane Austen",
            "Dumas, Alexandre, 1802-1870 " => "Alexandre Dumas",
            "Orwell, George." => "George Orwell",
            "Smith, Zadie." => "Zadie Smith",
            "Roth, Philip (Philip Milton)." => "Philip Roth",
            "Тартт, Донна." => "Донна Тартт",
            "Кинси, Ти." => "Ти Кинси",
            "Маас, Сара Дж., author" => "Сара Дж Маас",
            "Plato, author." => "Plato",
            "Brubaker, Ed" => "Ed Brubaker",
            "Traven, B., 1882?-1969." => "B. Traven",
            "Perse, Saint-John" => "Saint-John Perse",
            "Beaton, M.C." => "M.C. Beaton",
            "Tolkien, J.R.R." => "J.R.R. Tolkien",
            "Porter, Katherine Ann." => "Katherine Ann Porter",
            "Smith, K." => "K. Smith",
            "Dubeau, J.-F." => "J.-F. Dubeau",
            "நாகராஜன், ஜி." => "ஜி. நாகராஜன்",
            "Fyvel, T. R." => "T. R. Fyvel",
            "Le Guin, Ursula . K." => "Ursula K. Le Guin",
            "Beethoven, Ludwig van" => "Ludwig van Beethoven",
            "Gaulle, Charles de" => "Charles de Gaulle",
            "ჭეიშვილი, რეზო" => "რეზო ჭეიშვილი",
            "Иличевский, А.В." => "А.В. Иличевский",
            "Richard (Rick). Yancey" => "Richard Yancey",
            "Richard [Rick]. Yancey" => "Richard Yancey",
            "Matthew (Graphic novelist). Rosenberg" => "Matthew Rosenberg",
            "Rosenberg, Matthew (Graphic novelist)." => "Matthew Rosenberg",
            # not a shape we are sure of
            "University of California, Los Angeles" => nil,
            "Ministry of Culture, Sports and Tourism" => nil,
            "Phillips, Craig & Dean" => nil,
            "Nelson, Prince Rogers" => nil,
            "Ervine, St. John G." => nil,
            "荒木, 飛呂彦" => nil,
            "Yoshimoto, 吉本" => nil,
            "椿いづみ, author, artist" => nil,
            "蔡志忠, 1948- , editor, artist" => nil,
            "毛姆 Maugham, William Somerset 1874-1965" => nil,
            "هداىت، صادق، 1903=1951 author" => nil,
            "ثمىنى، نغمه،, author" => nil,
            "Smith, John / Jane Doe" => nil,
            "John Smith; Jane Doe" => nil,
            "John Smith | Jane Doe" => nil,
            "John Smith & Jane Doe" => nil,
            "Smith/Jones" => nil,
            "Gates, Henry Louis Jr." => nil,
            "Gates, Jr. Henry Louis" => nil,
            "Downs, Alan Ph. D." => nil,
            "Downs, Alan PhD" => nil,
            "Downs, MD Alan" => nil,
            "Press, Penguin" => nil,
            "Bank of England, London" => nil,
            "Marks and Spencer, London" => nil,
            "Time Inc, New York" => nil,
            "Acme Ltd, London" => nil,
            "Acme LLC, Dallas" => nil,
            "Smith Co, Dallas" => nil,
            "Smith Company, Dallas" => nil,
            "Penguin Press, New York" => nil,
            "Penguin Publishing, New York" => nil,
            "Brown University, Providence" => nil,
            "Ministry Culture, Seoul" => nil,
            "Department Health, London" => nil,
            "King, Stephen" => "Stephen King",
            "Bishop, Elizabeth" => "Elizabeth Bishop",
            "Pope, Alexander" => "Alexander Pope",
            "Chaucer, Geoffrey, approximately 1340-1400." => nil,
            "Homer, active 8th century B.C." => nil,
            "Henry Louis, Jr Gates" => nil,
            "Thomas, Aquinas, Saint, 1225?-1274." => nil,
            "More, Thomas, Saint, 1478-1535." => nil,
            "Leonardo, da Vinci, 1452-1519." => nil,
            "Marcus Aurelius, Emperor of Rome, 121-180." => nil,
            "Tolstoy, Leo, graf, 1828-1910." => nil,
            "DK Publishing, Inc" => nil,
            "Wizards of the Coast, Inc" => nil,
            "Little, Brown and Company" => nil,
            "Ellington, Duke" => nil,
            "Basie, Count" => nil,
            "Attenborough, Sir David" => nil,
            "hooks, bell" => nil,
            "cummings, e. e." => nil,
            "Sade, marquis de" => nil,
            "Хоффман, Элис, аuthor" => nil,
            "ჭეიშვილი, რეზო, 1933- author" => nil,
            "Brubaker, ed" => nil,
            "Smith, John, b." => nil,
            "Smith, John, ed" => nil,
            "Katherine,. Schwarzenegger Pratt" => nil,
            "Smith, Jr., John" => nil,
            "Smith, John, Mary" => nil,
            "Smith, de" => nil,
            "Smith, 1900-, Jr." => nil,
            "Smith, author, John" => nil,
            "Smith, John 1900" => nil,
            "(Author)" => nil,
            "" => nil
          }

          PEOPLE.each do |raw, expected|
            test "creator #{raw.inspect}" do
              actual = Names.world_cat_person(raw)
              expected.nil? ? assert_nil(actual) : assert_equal(expected, actual)
            end
          end

          # raw title, raw subtitle => [title, subtitle]
          TITLES = {
            ["The dispossessed : an ambiguous utopia / Ursula K. Le Guin.", nil] => ["The dispossessed", "an ambiguous utopia"],
            ["Either/Or : a fragment of life / Soren Kierkegaard.", nil] => ["Either/Or", "a fragment of life"],
            ["S/Z", nil] => ["S/Z", nil],
            ["9/11", nil] => ["9/11", nil],
            ["Ranma 1/2. Vol. 27", nil] => ["Ranma 1/2. Vol. 27", nil],
            ["80/20 triathlon", nil] => ["80/20 triathlon", nil],
            ["Superman/Batman", nil] => ["Superman/Batman", nil],
            ["The title /", nil] => ["The title", nil],
            ["Borges, mündlich/ Sieben Nächte", nil] => ["Borges, mündlich/ Sieben Nächte", nil],
            ["Pig /pork", nil] => ["Pig /pork", nil],
            ["The dispossessed", "an ambiguous utopia / Ursula K. Le Guin."] => ["The dispossessed", "an ambiguous utopia"],
            ["The Civil War.", nil] => ["The Civil War", nil],
            ["Title : a subtitle.", nil] => ["Title", "a subtitle"],
            ["A history of the U.S.A.", nil] => ["A history of the U.S.A.", nil],
            ["Rome, 753 B.C.", nil] => ["Rome, 753 B.C.", nil],
            ["Acme Inc.", nil] => ["Acme Inc.", nil],
            ["Smith Jr.", nil] => ["Smith Jr.", nil],
            ["Wait for it...", nil] => ["Wait for it...", nil],
            ["Title :", nil] => ["Title", nil]
          }

          TITLES.each do |(title, subtitle), expected|
            test "title #{title.inspect} with subtitle #{subtitle.inspect}" do
              assert_equal expected, Names.world_cat_title(title, subtitle)
            end
          end

          test "text deletes NULs, scrubs invalid bytes, squishes and caps" do
            assert_equal "A Quiet Year", Names.text("A  Quiet\u0000 \xC3 Year".b)
            assert_equal "ab", Names.text("a\u0000b")
            assert_equal 255, Names.text("x" * 300).length
            assert_nil Names.text("\u0000 ")
          end

          test "invalid UTF-8 in a creator or title does not raise" do
            bad = "Le Guin, Ursula \xC3".dup.force_encoding(Encoding::UTF_8)

            assert_equal "Ursula Le Guin", Names.world_cat_person(bad)
            assert_equal ["Title", "Sub"], Names.world_cat_title("Title", "Sub\xC3".dup.force_encoding(Encoding::UTF_8))
          end

          test "years: integers pass through, strings are parsed" do
            assert_equal [-700, 180, 1974, 1974, nil], [Names.year(-700), Names.year(180), Names.year(1974), Names.year("1974-05"), Names.year("n.d.")]
          end
        end
      end
    end
  end
end
