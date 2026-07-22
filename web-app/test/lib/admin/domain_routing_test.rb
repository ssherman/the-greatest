require "test_helper"

module Admin
  class DomainRoutingTest < ActiveSupport::TestCase
    test "domain_for resolves a record to its domain" do
      assert_equal :music, Admin::DomainRouting.domain_for(music_albums(:dark_side_of_the_moon))
      assert_equal :games, Admin::DomainRouting.domain_for(games_games(:breath_of_the_wild))
    end

    test "domain_for accepts a class" do
      assert_equal :music, Admin::DomainRouting.domain_for(::Music::Artist)
      assert_equal :games, Admin::DomainRouting.domain_for(::Games::Company)
    end

    test "domain_for returns nil for an unregistered class" do
      assert_nil Admin::DomainRouting.domain_for(User)
    end

    test "path_for returns the admin show path for every registered entity" do
      {
        music_artists(:david_bowie) => "/admin/artists",
        music_albums(:dark_side_of_the_moon) => "/admin/albums",
        music_songs(:time) => "/admin/songs",
        games_games(:breath_of_the_wild) => "/admin/games",
        games_companies(:nintendo) => "/admin/companies",
        books_books(:war_and_peace) => "/admin/books",
        books_editions(:wp_maude) => "/admin/editions"
      }.each do |record, prefix|
        assert_equal "#{prefix}/#{record.to_param}", Admin::DomainRouting.path_for(record)
      end
    end

    test "path_for returns nil for an unregistered record" do
      assert_nil Admin::DomainRouting.path_for(users(:regular_user))
    end

    test "path_for returns nil for an unpersisted record instead of raising" do
      assert_nil Admin::DomainRouting.path_for(::Music::Album.new)
    end

    test "path_for returns nil for a nil record instead of raising" do
      assert_nil Admin::DomainRouting.path_for(nil)
    end

    test "category_items_path_for returns the nested category items path" do
      album = music_albums(:dark_side_of_the_moon)
      assert_equal "/admin/albums/#{album.to_param}/category_items",
        Admin::DomainRouting.category_items_path_for(album)
    end

    test "category_items_path_for returns nil for an entity without categories" do
      assert_nil Admin::DomainRouting.category_items_path_for(games_companies(:nintendo))
    end

    test "list_config returns the listable type, paths and label" do
      list = lists(:music_albums_list)
      config = Admin::DomainRouting.list_config(list)

      assert_equal :music, config[:domain]
      assert_equal "Music::Album", config[:listable_type]
      assert_equal "Album", config[:item_label]
      assert_equal "/admin/albums/lists/#{list.to_param}", config[:path]
      assert_equal "/admin/albums/search", config[:autocomplete_path]
    end

    test "list_config covers every list type the admin can reach" do
      [
        {list: lists(:music_albums_list), path_prefix: "/admin/albums/lists", autocomplete_path: "/admin/albums/search"},
        {list: lists(:music_songs_list), path_prefix: "/admin/songs/lists", autocomplete_path: "/admin/songs/search"},
        {list: lists(:games_list), path_prefix: "/admin/lists", autocomplete_path: "/admin/games/search"}
      ].each do |example|
        list = example[:list]
        config = Admin::DomainRouting.list_config(list)

        assert config, "#{list.class} is not registered"
        assert config[:listable_type].present?
        assert config[:item_label].present?
        assert_equal "#{example[:path_prefix]}/#{list.to_param}", config[:path]
        assert_equal example[:autocomplete_path], config[:autocomplete_path]
      end
    end

    test "ranking_configuration_config exposes list type and eager-load includes" do
      rc = ranking_configurations(:games_global)
      config = Admin::DomainRouting.ranking_configuration_config(rc)

      assert_equal :games, config[:domain]
      assert_equal "Games::List", config[:list_type]
      assert_equal({item: :companies}, config[:ranked_item_includes])
      assert_equal "/admin/ranking_configurations/#{rc.to_param}", config[:path]
    end

    test "ranking_configuration_config registers all six ranking configuration types" do
      [
        {rc: ranking_configurations(:music_albums_global), path_prefix: "/admin/albums/ranking_configurations"},
        {rc: ranking_configurations(:music_songs_global), path_prefix: "/admin/songs/ranking_configurations"},
        {rc: ranking_configurations(:music_artists_global), path_prefix: "/admin/artists/ranking_configurations"},
        {rc: ranking_configurations(:games_global), path_prefix: "/admin/ranking_configurations"},
        {rc: ranking_configurations(:books_global), path_prefix: "/admin/ranking_configurations"},
        {rc: ranking_configurations(:movies_global), path_prefix: nil}
      ].each do |example|
        rc = example[:rc]
        config = Admin::DomainRouting.ranking_configuration_config(rc)

        assert config, "#{rc.class} is not registered"
        if example[:path_prefix]
          assert_equal "#{example[:path_prefix]}/#{rc.to_param}", config[:path]
        else
          assert_nil config[:path]
        end
      end
    end

    test "ranking_configuration_config returns a nil path for domains without an admin" do
      config = Admin::DomainRouting.ranking_configuration_config(::Movies::RankingConfiguration.new)

      assert_equal :movies, config[:domain]
      assert_equal "Movies::List", config[:list_type]
      assert_nil config[:path]
    end

    test "penalty_class resolves a type string" do
      assert_equal ::Music::Penalty, Admin::DomainRouting.penalty_class("Music::Penalty")
      assert_equal ::Games::Penalty, Admin::DomainRouting.penalty_class("Games::Penalty")
      assert_equal ::Books::Penalty, Admin::DomainRouting.penalty_class("Books::Penalty")
      assert_equal ::Global::Penalty, Admin::DomainRouting.penalty_class("nonsense")
    end

    test "parent_from_params finds a nested parent scoped to the domain" do
      artist = music_artists(:david_bowie)
      found = Admin::DomainRouting.parent_from_params(
        ActionController::Parameters.new(artist_id: artist.id),
        domain: :music
      )

      assert_equal artist, found
    end

    test "parent_from_params ignores params belonging to another domain" do
      game = games_games(:breath_of_the_wild)
      found = Admin::DomainRouting.parent_from_params(
        ActionController::Parameters.new(game_id: game.id),
        domain: :music
      )

      assert_nil found
    end

    test "domain_for resolves a Books::Book to books" do
      assert_equal :books, Admin::DomainRouting.domain_for(books_books(:war_and_peace))
      assert_equal :books, Admin::DomainRouting.domain_for(::Books::Book)
    end

    test "parent_from_params resolves a book_id under the books domain" do
      book = books_books(:war_and_peace)
      resolved = Admin::DomainRouting.parent_from_params({book_id: book.id}, domain: :books)
      assert_equal book, resolved
    end

    test "domain_for resolves a Books::Edition to books" do
      assert_equal :books, Admin::DomainRouting.domain_for(books_editions(:wp_maude))
      assert_equal :books, Admin::DomainRouting.domain_for(::Books::Edition)
    end

    test "parent_from_params resolves an edition_id under the books domain" do
      edition = books_editions(:wp_maude)
      resolved = Admin::DomainRouting.parent_from_params({edition_id: edition.id}, domain: :books)
      assert_equal edition, resolved
    end

    test "domain_for resolves a Books::Author to books" do
      assert_equal :books, Admin::DomainRouting.domain_for(books_authors(:tolstoy))
      assert_equal :books, Admin::DomainRouting.domain_for(::Books::Author)
    end

    test "path_for resolves a Books::Author admin path" do
      author = books_authors(:tolstoy)
      assert_equal "/admin/authors/#{author.slug}", Admin::DomainRouting.path_for(author)
    end

    test "parent_from_params resolves an author_id under the books domain" do
      author = books_authors(:tolstoy)
      resolved = Admin::DomainRouting.parent_from_params({author_id: author.id}, domain: :books)
      assert_equal author, resolved
    end

    test "domain_for resolves a Books::Series to books" do
      assert_equal :books, Admin::DomainRouting.domain_for(books_series(:asoiaf))
      assert_equal :books, Admin::DomainRouting.domain_for(::Books::Series)
    end

    test "path_for resolves a Books::Series admin path" do
      series = books_series(:asoiaf)
      assert_equal "/admin/series/#{series.slug}", Admin::DomainRouting.path_for(series)
    end

    test "parent_from_params resolves a series_id under the books domain" do
      series = books_series(:asoiaf)
      resolved = Admin::DomainRouting.parent_from_params({series_id: series.id}, domain: :books)
      assert_equal series, resolved
    end

    test "LISTS resolves a books list to the books book typeahead" do
      config = Admin::DomainRouting.list_config(::Books::List.new)
      assert_equal :books, config[:domain]
      assert_equal "Book", config[:item_label]
      assert_equal Rails.application.routes.url_helpers.search_admin_books_books_path, config[:autocomplete_path]
    end

    test "category_items_path_for resolves for a books book and author" do
      book = books_books(:war_and_peace)
      author = books_authors(:tolstoy)
      assert_equal Rails.application.routes.url_helpers.admin_books_book_category_items_path(book),
        Admin::DomainRouting.category_items_path_for(book)
      assert_equal Rails.application.routes.url_helpers.admin_books_author_category_items_path(author),
        Admin::DomainRouting.category_items_path_for(author)
    end

    test "RANKING_CONFIGURATIONS resolves a books RC path" do
      rc = ranking_configurations(:books_global)
      assert_equal Rails.application.routes.url_helpers.admin_books_ranking_configuration_path(rc),
        Admin::DomainRouting.ranking_configuration_config(rc)[:path]
    end
  end
end
