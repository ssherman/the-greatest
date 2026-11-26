require "test_helper"

class NewsPostPolicyTest < ActiveSupport::TestCase
  setup do
    @books_editor = users(:regular_user)
    DomainRole.create!(user: @books_editor, domain: :books, permission_level: :editor)
    @music_editor = users(:contractor_user)
  end

  test "domain is the post's own domain" do
    assert_equal "books", NewsPostPolicy.new(users(:admin_user), news_posts(:books_december_update)).domain
    assert_equal "music", NewsPostPolicy.new(users(:admin_user), news_posts(:music_launch)).domain
  end

  test "update is open to admins and to editors of the post's site only" do
    post = news_posts(:books_december_update)
    assert NewsPostPolicy.new(users(:admin_user), post).update?
    assert NewsPostPolicy.new(@books_editor, post).update?
    assert_not NewsPostPolicy.new(users(:books_viewer_user), post).update?
    assert_not NewsPostPolicy.new(@music_editor, post).update?
  end

  test "a music editor passes on a music post and a books editor does not" do
    post = news_posts(:music_launch)
    assert NewsPostPolicy.new(@music_editor, post).update?
    assert_not NewsPostPolicy.new(@books_editor, post).update?
  end

  test "create works on a new post of a site" do
    post = NewsPost.new(domain: :books)
    assert NewsPostPolicy.new(@books_editor, post).create?
    assert_not NewsPostPolicy.new(@music_editor, post).create?
  end
end
