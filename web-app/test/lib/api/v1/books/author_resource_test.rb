require "test_helper"

module Api
  module V1
    module Books
      class AuthorResourceTest < ActiveSupport::TestCase
        setup do
          Current.domain = :books
          @author = books_authors(:tolstoy)
        end

        test "compact shape" do
          hash = AuthorResource.new(@author, params: {rank: 4}).to_h

          assert_equal(
            %i[id slug name sort_name birth_year death_year rank image_url url api_url],
            hash.keys
          )
          assert_equal @author.id, hash[:id]
          assert_equal "leo-tolstoy", hash[:slug]
          assert_equal "Leo Tolstoy", hash[:name]
          assert_nil hash[:sort_name]
          assert_equal 1828, hash[:birth_year]
          assert_equal 1910, hash[:death_year]
          assert_equal 4, hash[:rank]
          assert_nil hash[:image_url]
          assert_equal "https://dev-new.thegreatestbooks.org/author/leo-tolstoy", hash[:url]
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/authors/leo-tolstoy", hash[:api_url]
        end

        test "rank falls back to the primary author ranking when not supplied" do
          RankedItem.create!(item: @author, ranking_configuration: ranking_configurations(:books_authors_global), rank: 3, score: 90)

          assert_equal 3, AuthorResource.new(@author).to_h[:rank]
        end

        test "rank ignores a ranking that is not the primary one" do
          RankedItem.create!(item: @author, ranking_configuration: ranking_configurations(:books_authors_secondary), rank: 3, score: 90)

          assert_nil AuthorResource.new(@author).to_h[:rank]
        end

        test "rank is null for an unranked author" do
          assert_nil AuthorResource.new(@author).to_h[:rank]
        end

        test "a rank of nil passed explicitly stays nil" do
          RankedItem.create!(item: @author, ranking_configuration: ranking_configurations(:books_authors_global), rank: 3, score: 90)

          assert_nil AuthorResource.new(@author, params: {rank: nil}).to_h[:rank]
        end

        test "image_url is the CDN URL of the primary image" do
          file = stub(attached?: true, key: "authors/abc123.jpg")
          @author.stubs(:primary_image).returns(stub(file: file))

          assert_equal "https://images-dev.thegreatestbooks.org/authors/abc123.jpg", AuthorResource.new(@author).to_h[:image_url]
        end

        test "image_url is null when the primary image has no attachment" do
          @author.stubs(:primary_image).returns(stub(file: stub(attached?: false)))

          assert_nil AuthorResource.new(@author).to_h[:image_url]
        end

        test "full trait adds the detail fields in order" do
          hash = AuthorResource.new(@author, with_traits: :full).to_h

          assert_equal(
            %i[id slug name sort_name birth_year death_year rank image_url url api_url
              alternate_names kind description],
            hash.keys
          )
          assert_equal ["Lev Tolstoy", "Lev Nikolayevich Tolstoy"], hash[:alternate_names]
          assert_equal "person", hash[:kind]
          # tolstoy carries one fixture description (descriptions.yml: tolstoy_google,
          # kind summary, locale en) -- Descriptions::Resolver returns it.
          assert_equal "Russian writer widely regarded as one of the greatest novelists.", hash[:description]
        end

        test "full trait never embeds books" do
          hash = AuthorResource.new(@author, with_traits: :full).to_h

          refute hash.key?(:books)
        end

        test "full trait renders the enum kind as a string" do
          assert_equal "pseudonym", AuthorResource.new(books_authors(:bachman), with_traits: :full).to_h[:kind]
        end

        test "full trait description is null for an author without one" do
          assert_nil AuthorResource.new(books_authors(:king), with_traits: :full).to_h[:description]
        end

        test "full trait description comes from the descriptions subsystem, not the legacy column" do
          author = books_authors(:king)
          author.update_column(:description, "Legacy column text")

          assert_nil AuthorResource.new(author.reload, with_traits: :full).to_h[:description]
        end

        test "full trait resolves a summary description assigned through Describable" do
          author = books_authors(:king)
          author.assign_description(source: :ai_generated, content: "Master of horror.", kind: :summary)
          author.save!

          assert_equal "Master of horror.", AuthorResource.new(author.reload, with_traits: :full).to_h[:description]
        end
      end
    end
  end
end
