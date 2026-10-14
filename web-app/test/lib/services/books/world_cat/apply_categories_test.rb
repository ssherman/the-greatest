require "test_helper"

module Services
  module Books
    module WorldCat
      class ApplyCategoriesTest < ActiveSupport::TestCase
        setup do
          @book = books_books(:war_and_peace)
          @map = ::Books::WorldCat::GenreMap.new(
            "genres" => ["Fiction", "Novels", "Americana"],
            "terms" => {
              "Fiction" => {"verdict" => "genre", "genre" => "Fiction"},
              "Romans" => {"verdict" => "genre", "genre" => "Fiction"},
              "novels" => {"verdict" => "genre", "genre" => "Novels"},
              "Americana" => {"verdict" => "genre", "genre" => "Americana"},
              "Politics and government" => {"verdict" => "subject", "subject" => "Politics"},
              "Napoleonic Wars" => {"verdict" => "subject", "subject" => "Napoleonic Wars"},
              "Large type books" => {"verdict" => "drop", "reason" => "format"}
            }
          )
        end

        def record(oclc, genre: nil, subjects: [])
          ::Books::WorldCat::Record.from_hash("oclc" => oclc, "genre" => genre, "subjects" => subjects)
        end

        def names(type)
          @book.reload.categories.where(category_type: type).order(:name).pluck(:name)
        end

        test "links a genre carried by at least two records" do
          records = [record(1, genre: "Fiction"), record(2, genre: "Romans"), record(3, genre: "novels")]
          result = ApplyCategories.call(book: @book, records: records, map: @map)
          assert result.success?
          assert_equal ["Fiction"], result.data[:genres_linked]
          assert_includes names(:genre), "Fiction"
          assert_equal 3, result.data[:records]
        end

        test "test_single_record_book_gets_its_genre" do
          result = ApplyCategories.call(book: @book, records: [record(1, genre: "Romans")], map: @map)
          assert_equal ["Fiction"], result.data[:genres_linked]
        end

        test "test_stray_term_on_one_of_many_records_is_ignored" do
          records = [record(1, genre: "Fiction"), record(2, genre: "Fiction")] + Array.new(28) { |i| record(10 + i, genre: "Large type books") }
          records << record(99, genre: "novels")
          result = ApplyCategories.call(book: @book, records: records, map: @map)
          assert_equal ["Fiction"], result.data[:genres_linked]
          assert_not_includes result.data[:genres_linked], "Novels"
        end

        test "an edition's genre on two of many genre-bearing records is ignored" do
          # thirty editions of a classic: twenty-eight say Fiction, a study edition says Americana twice
          records = Array.new(28) { |i| record(100 + i, genre: "Romans") } + [record(1, genre: "Americana"), record(2, genre: "Americana")]
          result = ApplyCategories.call(book: @book, records: records, map: @map)
          assert_equal ["Fiction"], result.data[:genres_linked]
          assert_not_includes names(:genre), "Americana"
        end

        test "a secondary genre on a quarter of the genre-bearing records is kept" do
          # eight records carry a genre (six Fiction, two Americana); records with no genre do not count against it
          records = Array.new(6) { |i| record(100 + i, genre: "Fiction") } + [record(1, genre: "Americana"), record(2, genre: "Americana")] +
            Array.new(20) { |i| record(200 + i, genre: nil, subjects: ["Napoleonic Wars"]) }
          result = ApplyCategories.call(book: @book, records: records, map: @map)
          assert_equal ["Americana", "Fiction"], result.data[:genres_linked]
        end

        test "subjects resolve by name or alternative name and unresolved phrases are reported, not created" do
          categories(:books_politics_subject).update!(alternative_names: ["Politics"])
          categories(:books_politics_subject).update!(name: "Government")
          records = [record(1, subjects: ["Politics and government", "Napoleonic Wars"]), record(2, subjects: ["Politics and government", "Napoleonic Wars"])]
          before = ::Books::Category.count
          result = ApplyCategories.call(book: @book, records: records, map: @map)
          assert_equal ["Government"], result.data[:subjects_linked]
          assert_equal ["Napoleonic Wars"], result.data[:subjects_unresolved]
          assert_equal before, ::Books::Category.count
        end

        test "a subject verdict on the genre field counts too" do
          records = [record(1, genre: "Politics and government"), record(2, genre: "Politics and government")]
          result = ApplyCategories.call(book: @book, records: records, map: @map)
          assert_equal ["Politics"], result.data[:subjects_linked]
        end

        test "is additive and idempotent" do
          assert_includes names(:genre), "Novels" # the fixture's existing link must survive
          records = [record(1, genre: "Fiction"), record(2, genre: "Fiction")]
          ApplyCategories.call(book: @book, records: records, map: @map)
          result = ApplyCategories.call(book: @book, records: records, map: @map)
          assert_equal ["Fiction", "Novels"], names(:genre).sort & ["Fiction", "Novels"]
          assert_equal 1, result.data[:already_linked]
          assert_equal 1, @book.category_items.where(category: categories(:books_fiction_genre)).count
        end

        test "a book already holding Nonfiction does not also get Fiction, and the conflict is counted" do
          @book.category_items.create!(category: categories(:books_nonfiction_genre))
          records = [record(1, genre: "Fiction"), record(2, genre: "Romans")]
          result = ApplyCategories.call(book: @book, records: records, map: @map)
          assert_equal [], result.data[:genres_linked]
          assert_equal 1, result.data[:type_conflicts]
          assert_not_includes names(:genre), "Fiction"
          assert_includes names(:genre), "Nonfiction"
        end

        test "a book with no type gets Fiction and no conflict" do
          records = [record(1, genre: "Fiction"), record(2, genre: "Romans")]
          result = ApplyCategories.call(book: @book, records: records, map: @map)
          assert_equal ["Fiction"], result.data[:genres_linked]
          assert_equal 0, result.data[:type_conflicts]
        end

        test "a record whose number a later pass merged away counts once" do
          old = ::Books::WorldCat::Record.from_hash("oclc" => 1, "genre" => "Romans")
          newer = ::Books::WorldCat::Record.from_hash("oclc" => 2, "genre" => "Romans", "merged_oclc" => [1])
          result = ApplyCategories.call(book: @book, records: [old, newer], map: @map)
          assert_equal 1, result.data[:records]
          assert_equal ["Fiction"], result.data[:genres_linked]
        end

        test "never infers Nonfiction and never links a deleted category" do
          ::Books::Category.active.genre.by_name("Fiction").update_all(deleted: true)
          records = [record(1, genre: "Fiction"), record(2, genre: "Fiction")]
          result = ApplyCategories.call(book: @book, records: records, map: @map)
          assert_equal [], result.data[:genres_linked]
          assert_not_includes names(:genre), "Nonfiction"
        end

        test "no records is a success that links nothing" do
          result = ApplyCategories.call(book: @book, records: [], map: @map)
          assert result.success?
          assert_equal 0, result.data[:records]
        end
      end
    end
  end
end
