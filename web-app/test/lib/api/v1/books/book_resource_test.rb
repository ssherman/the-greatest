require "test_helper"

module Api
  module V1
    module Books
      class BookResourceTest < ActiveSupport::TestCase
        setup do
          Current.domain = :books
          @book = books_books(:war_and_peace)
        end

        test "compact shape" do
          hash = BookResource.new(@book, params: {rank: 7}).to_h

          assert_equal(
            %i[id slug title subtitle first_published_year rank authors cover_url url api_url],
            hash.keys
          )
          assert_equal @book.id, hash[:id]
          assert_equal "war-and-peace", hash[:slug]
          assert_equal "War and Peace", hash[:title]
          assert_nil hash[:subtitle]
          assert_equal 1869, hash[:first_published_year]
          assert_equal 7, hash[:rank]
          assert_equal [{id: books_authors(:tolstoy).id, slug: "leo-tolstoy", name: "Leo Tolstoy"}], hash[:authors]
          assert_nil hash[:cover_url]
          assert_equal "https://dev-new.thegreatestbooks.org/book/war-and-peace", hash[:url]
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/books/war-and-peace", hash[:api_url]
        end

        test "rank falls back to the primary ranking when not supplied" do
          RankedItem.create!(item: @book, ranking_configuration: ranking_configurations(:books_global), rank: 3, score: 90)

          assert_equal 3, BookResource.new(@book).to_h[:rank]
        end

        test "rank is null for an unranked book" do
          assert_nil BookResource.new(@book).to_h[:rank]
        end

        test "a rank of nil passed explicitly stays nil" do
          assert_nil BookResource.new(@book, params: {rank: nil}).to_h[:rank]
        end

        test "authors are in position order" do
          second = books_authors(:garnett)
          ::Books::BookAuthor.create!(book: @book, author: second, position: 2, role: 0)

          assert_equal ["leo-tolstoy", second.slug], BookResource.new(@book.reload).to_h[:authors].map { |a| a[:slug] }
        end

        test "cover_url is the CDN URL of the primary image" do
          file = stub(attached?: true, key: "covers/abc123.jpg")
          @book.stubs(:primary_image).returns(stub(file: file))

          assert_equal "https://images-dev.thegreatestbooks.org/covers/abc123.jpg", BookResource.new(@book).to_h[:cover_url]
        end

        test "full trait adds the detail fields in order" do
          hash = BookResource.new(@book, with_traits: :full).to_h

          assert_equal(
            %i[id slug title subtitle first_published_year rank authors cover_url url api_url
              sort_title alternate_titles book_kind book_length page_range word_count description
              original_language categories countries],
            hash.keys
          )
          assert_equal ["Voyna i mir"], hash[:alternate_titles]
          assert_equal "standalone", hash[:book_kind]
          assert_nil hash[:book_length]
          # war_and_peace carries fixture descriptions (test/fixtures/descriptions.yml);
          # Descriptions::Resolver picks the ai_generated one over wikipedia by
          # SourcePriority::ORDER, deterministically, when both are un-preferred.
          assert_equal "An epic chronicle of Russian society through the Napoleonic wars.", hash[:description]
          language = languages(:russian)
          assert_equal({id: language.id, slug: language.slug, name: language.name}, hash[:original_language])
          # war_and_peace carries fixture categories too (test/fixtures/category_items.yml);
          # sort by id since the through association has no explicit order.
          expected_categories = [categories(:books_novels_genre), categories(:books_classics_genre)]
            .map { |c| {id: c.id, slug: c.slug, name: c.name, category_type: "genre"} }
            .sort_by { |c| c[:id] }
          assert_equal expected_categories, hash[:categories].sort_by { |c| c[:id] }
          # war_and_peace already links to this country fixture (see also
          # test/lib/books/book/merger_test.rb).
          french = books_countries(:french)
          assert_equal [{id: french.id, slug: "french", name: "French"}], hash[:countries]
        end

        test "full trait resolves the primary summary description" do
          @book.assign_description(source: :ai_generated, content: "A long Russian novel.", kind: :summary)
          @book.save!

          assert_equal "A long Russian novel.", BookResource.new(@book.reload, with_traits: :full).to_h[:description]
        end

        test "full trait lists active categories and countries with slugs" do
          category = ::Books::Category.create!(name: "Novel", category_type: :genre)
          deleted = ::Books::Category.create!(name: "Gone", category_type: :genre, deleted: true)
          CategoryItem.create!(category: category, item: @book)
          CategoryItem.create!(category: deleted, item: @book)
          country = ::Books::Country.create!(name: "Russia", slug: "russia")
          ::Books::BookCountry.create!(book: @book, country: country)

          hash = BookResource.new(@book.reload, with_traits: :full).to_h

          # war_and_peace already carries two fixture categories (Novels, Classics);
          # the new one must join them, and the deleted one must not appear. Sort by
          # id since the through association has no explicit order.
          expected_categories = [
            categories(:books_novels_genre),
            categories(:books_classics_genre)
          ].map { |c| {id: c.id, slug: c.slug, name: c.name, category_type: "genre"} }
          expected_categories << {id: category.id, slug: category.slug, name: "Novel", category_type: "genre"}
          assert_equal expected_categories.sort_by { |c| c[:id] }, hash[:categories].sort_by { |c| c[:id] }
          # war_and_peace already links to books_countries(:french); the new country
          # must join it, sorted by id since the through association has no explicit
          # order.
          french = books_countries(:french)
          expected_countries = [
            {id: french.id, slug: "french", name: "French"},
            {id: country.id, slug: "russia", name: "Russia"}
          ].sort_by { |c| c[:id] }
          assert_equal expected_countries, hash[:countries].sort_by { |c| c[:id] }
        end
      end
    end
  end
end
