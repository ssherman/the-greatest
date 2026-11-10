require "test_helper"

module Services
  module Books
    module Categories
      class SupportTest < ActiveSupport::TestCase
        setup do
          @book = ::Books::Book.create!(title: "Support Test Book", first_published_year: 1900, original_language: Language.first)
        end

        def category(name, type, **attrs) = ::Books::Category.create!(name: name, category_type: type, **attrs)

        def dossier(wikidata: nil, wikipedia: nil, worldcat: nil, goodreads: nil)
          Categorize::Dossier.new(book: @book, evidence_id: nil, record: {}, book_facts: nil,
            wikidata: wikidata, wikipedia: wikipedia, worldcat: worldcat, goodreads: goodreads)
        end

        def support(**sections) = Support.new(dossier(**sections))

        test "wikidata backs a category named in genres, main subjects, narrative locations or forms" do
          assert_equal ["wikidata"], support(wikidata: {"genres" => ["satire"]}).sources_for(category("Satire", "genre"))
          assert_equal ["wikidata"], support(wikidata: {"main_subjects" => ["War"]}).sources_for(category("War", "subject"))
          assert_equal ["wikidata"], support(wikidata: {"narrative_locations" => ["Paris"]}).sources_for(category("Paris", "location"))
          assert_equal ["wikidata"], support(wikidata: {"forms" => ["Epistolary"]}).sources_for(category("Epistolary", "genre"))
          assert_empty support(wikidata: {"genres" => ["Poetry"]}).sources_for(category("Satire", "genre"))
        end

        test "the match is whole-word, so War does not match Warsaw" do
          war = category("War", "subject")
          assert_empty support(wikidata: {"main_subjects" => ["Warsaw"]}).sources_for(war)
          assert_equal ["wikidata"], support(wikidata: {"main_subjects" => ["War and peace"]}).sources_for(war)
        end

        test "alternative names count" do
          sf = category("Science Fiction", "genre", alternative_names: ["Sci-Fi"])
          assert_equal ["wikidata"], support(wikidata: {"genres" => ["sci-fi"]}).sources_for(sf)
        end

        test "a label equal to an alternative name of a category merged into this one counts" do
          target = category("Fantasy", "genre")
          category("Fantastic", "genre", alternative_names: ["Wonder Tales"], deleted: true, merged_into_id: target.id)
          assert_equal ["wikidata"], support(wikidata: {"genres" => ["Wonder Tales"]}).sources_for(target)
          assert_equal ["wikidata"], support(wikidata: {"genres" => ["Fantastic"]}).sources_for(target)
        end

        test "wikipedia backs a category through the infobox" do
          novel = category("Gothic", "genre")
          place = category("Verona", "location")
          assert_equal ["wikipedia"], support(wikipedia: {"infobox_genre" => "Gothic novel"}).sources_for(novel)
          assert_equal ["wikipedia"], support(wikipedia: {"infobox_set_in" => "Verona, Italy"}).sources_for(place)
          assert_empty support(wikipedia: {"infobox_genre" => nil, "infobox_subject" => nil, "infobox_set_in" => nil}).sources_for(novel)
        end

        test "worldcat backs genres and audiences by mapped key, subjects and locations by heading" do
          genre = category("Mystery", "genre")
          audience = category("Young Adult", "audience")
          subject = category("Revolutions", "subject")
          worldcat = {"mapped_genres" => {"genre:Mystery" => 3, "audience:Young Adult" => 1}, "subjects" => ["France -- Revolutions"]}
          sup = support(worldcat: worldcat)
          assert_equal ["worldcat"], sup.sources_for(genre)
          assert_equal ["worldcat"], sup.sources_for(audience)
          assert_equal ["worldcat"], sup.sources_for(subject)
          assert_empty sup.sources_for(category("Romance", "genre"))
          assert_empty support(worldcat: {"mapped_genres" => {"genre:Mystery" => 1}, "subjects" => []}).sources_for(subject)
        end

        test "a worldcat genre key does not back an audience of the same name" do
          audience = category("Thriller", "audience")
          assert_empty support(worldcat: {"mapped_genres" => {"genre:Thriller" => 2}, "subjects" => []}).sources_for(audience)
        end

        test "goodreads backs a category a shelf maps to, and not one it does not" do
          shelfy = category("Cozy Mystery", "genre")
          assert_equal ["goodreads"], support(goodreads: {"genres" => ["cozy mystery"]}).sources_for(shelfy)
          assert_empty support(goodreads: {"genres" => ["something else"]}).sources_for(shelfy)
          assert_empty support(goodreads: nil).sources_for(shelfy)
        end

        test "sources combine and supported? follows them" do
          genre = category("Satire", "genre")
          sup = support(wikidata: {"genres" => ["Satire"]}, wikipedia: {"infobox_genre" => "satire"})
          assert_equal %w[wikidata wikipedia], sup.sources_for(genre)
          assert sup.supported?(genre)
          assert_not support.supported?(genre)
        end
      end
    end
  end
end
