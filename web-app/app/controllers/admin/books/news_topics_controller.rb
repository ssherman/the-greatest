class Admin::Books::NewsTopicsController < Admin::NewsTopicsBaseController
  include Admin::DomainScopedAuth

  private

  def news_domain = :books

  def news_topics_path_for(params = {}) = admin_books_news_topics_path(params)

  def news_topic_path_for(topic) = admin_books_news_topic_path(topic)

  def new_news_topic_path_for = new_admin_books_news_topic_path

  def edit_news_topic_path_for(topic) = edit_admin_books_news_topic_path(topic)
end
