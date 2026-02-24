module Games::DefaultHelper
  def games_game_path_with_rc(game, ranking_configuration = nil)
    if ranking_configuration && !ranking_configuration.default_primary?
      game_path(game, ranking_configuration_id: ranking_configuration.id)
    else
      game_path(game)
    end
  end

  def link_to_game(game, ranking_configuration = nil, **options, &block)
    path = games_game_path_with_rc(game, ranking_configuration)
    if block_given?
      link_to path, **options, &block
    else
      link_to game.title, path, **options
    end
  end
end
