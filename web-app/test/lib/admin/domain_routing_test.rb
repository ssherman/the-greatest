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

    test "path_for returns the admin show path" do
      album = music_albums(:dark_side_of_the_moon)
      assert_equal "/admin/albums/#{album.to_param}", Admin::DomainRouting.path_for(album)

      game = games_games(:breath_of_the_wild)
      assert_equal "/admin/games/#{game.to_param}", Admin::DomainRouting.path_for(game)
    end

    test "path_for returns nil for an unregistered record" do
      assert_nil Admin::DomainRouting.path_for(users(:regular_user))
    end

    test "list_config returns the listable type, paths and label" do
      config = Admin::DomainRouting.list_config(::Music::Albums::List.new)

      assert_equal :music, config[:domain]
      assert_equal "Music::Album", config[:listable_type]
      assert_equal "Album", config[:item_label]
      assert_equal "/admin/albums/search", config[:autocomplete_path]
    end

    test "list_config covers every list type the admin can reach" do
      %w[Music::Albums::List Music::Songs::List Games::List].each do |type|
        config = Admin::DomainRouting.list_config(type.constantize.new)
        assert config, "#{type} is not registered"
        assert config[:listable_type].present?
        assert config[:item_label].present?
      end
    end

    test "ranking_configuration_config exposes list type and eager-load includes" do
      config = Admin::DomainRouting.ranking_configuration_config(::Games::RankingConfiguration.new)

      assert_equal :games, config[:domain]
      assert_equal "Games::List", config[:list_type]
      assert_equal({item: :companies}, config[:ranked_item_includes])
    end

    test "ranking_configuration_config registers all six ranking configuration types" do
      %w[
        Music::Albums::RankingConfiguration
        Music::Songs::RankingConfiguration
        Music::Artists::RankingConfiguration
        Games::RankingConfiguration
        Books::RankingConfiguration
        Movies::RankingConfiguration
      ].each do |type|
        assert Admin::DomainRouting.ranking_configuration_config(type.constantize.new),
          "#{type} is not registered"
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
