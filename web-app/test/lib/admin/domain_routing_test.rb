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
        games_companies(:nintendo) => "/admin/companies"
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
        {rc: ranking_configurations(:books_global), path_prefix: nil},
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
      config = Admin::DomainRouting.ranking_configuration_config(::Books::RankingConfiguration.new)

      assert_equal :books, config[:domain]
      assert_equal "Books::List", config[:list_type]
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
  end
end
