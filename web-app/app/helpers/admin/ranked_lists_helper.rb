module Admin::RankedListsHelper
  def penalty_badge_class(penalty_value)
    return "badge-success" if penalty_value < 10
    return "badge-warning" if penalty_value < 25
    "badge-error"
  end

  def ranking_configuration_back_path(ranking_configuration)
    Admin::DomainRouting.ranking_configuration_config(ranking_configuration)&.dig(:path) || music_root_path
  end

  def ranked_list_link(list, **html_options)
    path = Admin::DomainRouting.list_config(list)&.dig(:path)
    return list.name unless path

    link_to list.name, path, {class: "link link-primary"}.merge(html_options)
  end

  def ranking_configuration_link(ranking_configuration)
    path = Admin::DomainRouting.ranking_configuration_config(ranking_configuration)&.dig(:path)
    return ranking_configuration.name unless path

    link_to ranking_configuration.name, path, class: "link link-primary"
  end
end
