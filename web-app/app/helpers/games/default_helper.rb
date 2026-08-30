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

  def games_list_path_with_rc(list, ranking_configuration = nil)
    if ranking_configuration && !ranking_configuration.default_primary?
      games_list_path(id: list, ranking_configuration_id: ranking_configuration.id)
    else
      games_list_path(id: list)
    end
  end

  def games_lists_path_with_rc(**options)
    rc = params[:ranking_configuration_id].presence
    rc ? games_lists_path(ranking_configuration_id: rc, **options) : games_lists_path(**options)
  end

  def games_category_path_with_rc(category, ranking_configuration = nil)
    if ranking_configuration && !ranking_configuration.default_primary?
      games_category_path(category, ranking_configuration_id: ranking_configuration.id)
    else
      games_category_path(category)
    end
  end

  def link_to_game_category(category, ranking_configuration = nil, **options, &block)
    path = games_category_path_with_rc(category, ranking_configuration)
    if block_given?
      link_to path, **options, &block
    else
      link_to category.name, path, **options
    end
  end

  def link_to_game_list(list, ranking_configuration = nil, **options, &block)
    path = games_list_path_with_rc(list, ranking_configuration)
    if block_given?
      link_to path, **options, &block
    else
      link_to list.name, path, **options
    end
  end

  def games_robots_content
    return "noindex, follow" if params[:ranking_configuration_id].present?
    (@indexable == false) ? "noindex, follow" : "index, follow"
  end
end
