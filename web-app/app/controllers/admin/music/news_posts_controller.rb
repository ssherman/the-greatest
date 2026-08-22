class Admin::Music::NewsPostsController < Admin::NewsPostsBaseController
  include Admin::DomainScopedAuth

  private

  def news_domain = :music

  def news_posts_path_for(params = {}) = admin_news_posts_path(params)

  def news_post_path_for(post) = admin_news_post_path(post)

  def new_news_post_path_for = new_admin_news_post_path

  def edit_news_post_path_for(post) = edit_admin_news_post_path(post)

  def preview_news_posts_path_for = preview_admin_news_posts_path
end
