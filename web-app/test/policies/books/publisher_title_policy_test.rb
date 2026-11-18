require "test_helper"
require_relative "domain_policy_assertions"

module Books
  class PublisherTitlePolicyTest < ActiveSupport::TestCase
    include Books::DomainPolicyAssertions

    setup do
      @title = books_publisher_titles(:ready_title)
    end

    test "domain is books" do
      assert_equal "books", ::Books::PublisherTitlePolicy.new(users(:admin_user), @title).domain
    end

    test "grants access by global role and books domain role" do
      assert_books_domain_policy(::Books::PublisherTitlePolicy, @title)
    end

    test "a music-only user has no access" do
      refute ::Books::PublisherTitlePolicy.new(music_user, @title).show?
    end

    test "Scope resolves for books readers only" do
      assert_books_scope(::Books::PublisherTitlePolicy, ::Books::PublisherTitle)
    end
  end
end
