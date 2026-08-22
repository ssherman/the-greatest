class Admin::Games::NewsTopicsController < Admin::NewsTopicsBaseController
  include Admin::DomainScopedAuth

  private

  def news_domain = :games

  def news_topics_path_for(params = {}) = admin_games_news_topics_path(params)

  def news_topic_path_for(topic) = admin_games_news_topic_path(topic)

  def new_news_topic_path_for = new_admin_games_news_topic_path

  def edit_news_topic_path_for(topic) = edit_admin_games_news_topic_path(topic)
end
