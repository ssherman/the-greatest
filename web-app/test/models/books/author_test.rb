require "test_helper"

# == Schema Information
#
# Table name: books_authors
#
#  id                    :bigint           not null, primary key
#  alternate_names       :string           default([]), not null, is an Array
#  birth_year            :integer
#  death_year            :integer
#  description           :text
#  exclude_from_rankings :boolean          default(FALSE), not null
#  gender                :integer
#  kind                  :integer          default("person"), not null
#  name                  :string           not null
#  name_keys             :string           default([]), not null, is an Array
#  provisional           :boolean          default(FALSE), not null
#  slug                  :string           not null
#  sort_name             :string
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#
# Indexes
#
#  index_books_authors_on_alternate_names  (alternate_names) USING gin
#  index_books_authors_on_gender           (gender)
#  index_books_authors_on_kind             (kind)
#  index_books_authors_on_lower_name       (lower((name)::text))
#  index_books_authors_on_name_keys        (name_keys) USING gin
#  index_books_authors_on_provisional      (provisional) WHERE provisional
#  index_books_authors_on_slug             (slug) UNIQUE
#
module Books
  class AuthorTest < ActiveSupport::TestCase
    test "is valid with a name" do
      assert_predicate Books::Author.new(name: "Leo Tolstoy"), :valid?
    end

    test "requires a name" do
      author = Books::Author.new
      assert_not author.valid?
      assert_includes author.errors[:name], "can't be blank"
    end

    test "generates a slug from the name" do
      author = Books::Author.create!(name: "Fyodor Dostoevsky")
      assert_equal "fyodor-dostoevsky", author.slug
    end

    test "saving sets name_keys from the name and alternate names, initials folded, each once" do
      author = Books::Author.create!(name: "J.D. Salinger", alternate_names: ["J. D. Salinger", "Jerome David Salinger"])

      assert_equal ["j d salinger", "jerome david salinger"], author.name_keys
    end

    test "changing the name or an alternate name updates name_keys" do
      author = Books::Author.create!(name: "J.D. Salinger")

      author.update!(name: "Jerome Salinger", alternate_names: ["J. D. Salinger"])

      assert_equal ["jerome salinger", "j d salinger"], author.reload.name_keys
    end

    # Fixtures are inserted without callbacks, so their name_keys are written
    # by hand in authors.yml. This keeps them honest.
    test "every author fixture carries the name_keys its names produce" do
      Books::Author.find_each do |author|
        assert_equal Services::Text::PersonNameKey.all([author.name, *author.alternate_names]), author.name_keys, author.name
      end
    end

    test "defaults to person kind" do
      assert_predicate Books::Author.new(name: "X"), :person?
    end

    test "supports pseudonym kind" do
      assert_predicate books_authors(:bachman), :pseudonym?
    end

    test "as_indexed_json includes name and alternate_names" do
      json = books_authors(:tolstoy).as_indexed_json
      assert_equal "Leo Tolstoy", json[:name]
      assert_kind_of Array, json[:alternate_names]
    end

    # SearchIndexable concern tests
    test "should create search index request on create" do
      assert_difference "SearchIndexRequest.count", 1 do
        Books::Author.create!(name: "Test Search Author")
      end

      request = SearchIndexRequest.last
      assert_equal "Books::Author", request.parent_type
      assert request.index_item?
    end

    test "should create search index request on destroy" do
      author = books_authors(:garnett)

      assert_difference "SearchIndexRequest.count", 1 do
        author.destroy!
      end

      request = SearchIndexRequest.last
      assert_equal author.id, request.parent_id
      assert_equal "Books::Author", request.parent_type
      assert request.unindex_item?
    end

    # Search freshness: renaming an author reindexes their books
    test "renaming an author enqueues its books for reindexing" do
      author = books_authors(:tolstoy)
      book = books_books(:war_and_peace) # linked via war_and_peace_tolstoy fixture

      assert_difference -> { SearchIndexRequest.where(parent_type: "Books::Book", parent_id: book.id, action: SearchIndexRequest.actions[:index_item]).count }, 1 do
        author.update!(name: "Lev Tolstoy")
      end
    end

    test "a non-name author change does not enqueue its books for reindexing" do
      author = books_authors(:tolstoy)
      book = books_books(:war_and_peace)

      assert_no_difference -> { SearchIndexRequest.where(parent_type: "Books::Book", parent_id: book.id, action: SearchIndexRequest.actions[:index_item]).count } do
        author.update!(birth_year: 1829)
      end
    end

    test "exclude_from_rankings defaults to false" do
      author = Books::Author.new(name: "Test Author")

      assert_not author.exclude_from_rankings
    end

    test "exclude_from_rankings can be set" do
      assert books_authors(:excluded_placeholder).exclude_from_rankings
    end

    test "gender enum ordinals match the legacy authors.gender enum" do
      assert_equal({"male" => 0, "female" => 1, "non_binary" => 2, "unspecified" => 3},
        Books::Author.genders)
    end

    test "gender is optional" do
      author = Books::Author.new(name: "Anon")
      assert author.valid?
      assert_nil author.gender
    end

    test "authors can be scoped by gender" do
      garnett = books_authors(:garnett)
      garnett.update!(gender: :female)

      assert_includes Books::Author.where(gender: :female), garnett
    end

    # primary_ranked_item: the API's show reads the author's rank through this
    # (mirrors Books::Book#primary_ranked_item).
    test "primary_ranked_item is the row in the default primary author ranking" do
      author = books_authors(:tolstoy)
      RankedItem.create!(item: author, ranking_configuration: ranking_configurations(:books_authors_secondary), rank: 9, score: 10)
      RankedItem.create!(item: author, ranking_configuration: ranking_configurations(:books_authors_global), rank: 2, score: 90)

      assert_equal 2, Books::Author.find(author.id).primary_ranked_item.rank
    end

    test "primary_ranked_item is nil for an author the primary ranking does not rank" do
      author = books_authors(:king)
      RankedItem.create!(item: author, ranking_configuration: ranking_configurations(:books_authors_secondary), rank: 1, score: 100)

      assert_nil Books::Author.find(author.id).primary_ranked_item
    end

    test "primary_ranked_item is nil when there is no primary author ranking" do
      author = books_authors(:tolstoy)
      RankedItem.create!(item: author, ranking_configuration: ranking_configurations(:books_authors_global), rank: 1, score: 100)
      Books::Authors::RankingConfiguration.stubs(:default_primary).returns(nil)

      assert_nil Books::Author.find(author.id).primary_ranked_item
    end

    test "normalizes exotic whitespace in the name on save" do
      author = ::Books::Author.create!(name: "Kathleen Alcott")

      assert_equal "Kathleen Alcott", author.reload.name
    end

    test "normalizes, drops blanks from, and dedupes alternate_names on save" do
      author = ::Books::Author.create!(name: "Brian O'Nolan", alternate_names: ["Flann O\u2019Brien", "Flann O'Brien", "", "Flann O'Brien"])

      assert_equal ["Flann O'Brien"], author.reload.alternate_names
    end

    test "catalog excludes provisional authors and keeps the rest" do
      provisional = Books::Author.create!(name: "A Provisional Author", provisional: true)

      assert_includes Books::Author.catalog, books_authors(:tolstoy)
      refute_includes Books::Author.catalog, provisional
    end

    test "as_indexed_json carries the provisional flag" do
      author = books_authors(:tolstoy)

      assert_equal false, author.as_indexed_json[:provisional]
      author.provisional = true
      assert_equal true, author.as_indexed_json[:provisional]
    end

    test "destroying a legacy-origin author records it as deleted" do
      author = ::Books::Author.create!(id: 1_001, name: "Legacy Origin Author")

      author.destroy!

      row = RecordRedirect.find_by!(item_type: "Books::Author", from_id: 1_001)
      assert_nil row.to_id
    end
  end
end
