require "test_helper"

class ApplicationControllerTest < ActiveSupport::TestCase
  def resolve_domain_for(host, domains)
    controller = ApplicationController.new
    controller.stubs(:request).returns(stub(host: host))
    Rails.application.config.stubs(:domains).returns(domains)
    controller.send(:detect_current_domain)
  end

  test "resolves each single-host domain and defaults an unknown host to books" do
    domains = {music: "music.test", movies: "movies.test", games: "games.test", books: "books.test"}

    assert_equal :music, resolve_domain_for("music.test", domains)
    assert_equal :movies, resolve_domain_for("movies.test", domains)
    assert_equal :games, resolve_domain_for("games.test", domains)
    assert_equal :books, resolve_domain_for("books.test", domains)
    assert_equal :books, resolve_domain_for("unknown.test", domains)
  end

  test "resolves a secondary host listed in a comma-separated domain config" do
    domains = {music: "music.test,www.music.test", movies: "movies.test", games: "games.test", books: "books.test"}

    assert_equal :music, resolve_domain_for("www.music.test", domains)
    assert_equal :music, resolve_domain_for("music.test", domains)
    assert_equal :books, resolve_domain_for("unknown.test", domains)
  end
end
