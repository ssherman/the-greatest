require "test_helper"

module Admin
  class DomainNavTest < ActiveSupport::TestCase
    test "chrome_for returns theme, stylesheet, title and favicon per domain" do
      music = Admin::DomainNav.chrome_for(:music)
      assert_equal "light", music[:theme]
      assert_equal "music", music[:stylesheet]
      assert_equal "The Greatest Music", music[:title]
      assert_equal "music/favicon", music[:favicon_dir]

      games = Admin::DomainNav.chrome_for(:games)
      assert_equal "light", games[:theme]
      assert_equal "games", games[:stylesheet]
      assert_equal "The Greatest Games", games[:title]
      assert_nil games[:favicon_dir]

      books = Admin::DomainNav.chrome_for(:books)
      assert_equal "cmyk", books[:theme]
      assert_equal "books", books[:stylesheet]
      assert_equal "The Greatest Books", books[:title]
      assert_nil books[:favicon_dir]
    end

    test "chrome_for falls back to music chrome for domains with no admin" do
      [:movies, nil].each do |domain|
        chrome = Admin::DomainNav.chrome_for(domain)
        assert_equal "light", chrome[:theme]
        assert_equal "music", chrome[:stylesheet]
        assert_equal "The Greatest Music", chrome[:title]
        assert_equal "music/favicon", chrome[:favicon_dir]
      end
    end

    test "the single admin layout template exists" do
      assert File.exist?(Rails.root.join("app/views/layouts/admin.html.erb"))
    end

    test "config_for returns title, root path, section heading and nav items" do
      config = Admin::DomainNav.config_for(:games)

      assert_equal "The Greatest Games", config[:title]
      assert_equal "/admin", config[:root_path]
      assert_equal "Games", config[:section_label]
      assert config[:section_icon].present?
      assert config[:items].any?
    end

    test "nav items all carry a label, path and icon" do
      Admin::DomainNav::CONFIGS.each_key do |domain|
        Admin::DomainNav.config_for(domain)[:items].each do |item|
          assert item[:label].present?, "#{domain} item missing label"
          assert item[:path].present?, "#{domain} item #{item[:label]} missing path"
          assert item[:icon].present?, "#{domain} item #{item[:label]} missing icon"
        end
      end
    end

    test "config_for returns nil for a domain with no admin" do
      assert_nil Admin::DomainNav.config_for(:movies)
    end

    test "config_for returns the books config with a Books nav item" do
      config = Admin::DomainNav.config_for(:books)

      assert_equal "The Greatest Books", config[:title]
      assert_equal "/admin", config[:root_path]
      assert_equal "Books", config[:section_label]
      assert config[:section_icon].present?

      books_item = config[:items].find { |item| item[:label] == "Books" }
      assert books_item, "books nav is missing a Books item"
      assert_equal "/admin/books", books_item[:path]
      assert books_item[:icon].present?
    end

    test "the books nav includes an Authors item" do
      config = Admin::DomainNav.config_for(:books)
      authors_item = config[:items].find { |item| item[:label] == "Authors" }
      assert authors_item, "books nav is missing an Authors item"
      assert_equal "/admin/authors", authors_item[:path]
      assert authors_item[:icon].present?
    end

    test "the books nav includes a Series item pointing at the index" do
      config = Admin::DomainNav.config_for(:books)
      series_item = config[:items].find { |item| item[:label] == "Series" }
      assert series_item, "books nav is missing a Series item"
      assert_equal "/admin/series", series_item[:path]
      assert series_item[:icon].present?
    end

    test "a domain whose nav links to Categories has a categories_search_path" do
      Admin::DomainNav::CONFIGS.each_key do |domain|
        config = Admin::DomainNav.config_for(domain)
        next unless config[:items].any? { |item| item[:label] == "Categories" }

        assert config[:categories_search_path].present?,
          "#{domain} links to Categories but is missing categories_search_path"
      end
    end

    test "the books nav includes a Categories item with a categories_search_path" do
      config = Admin::DomainNav.config_for(:books)
      categories_item = config[:items].find { |item| item[:label] == "Categories" }
      assert categories_item, "books nav is missing a Categories item"
      assert_equal "/admin/categories", categories_item[:path]
      assert categories_item[:icon].present?
      assert config[:categories_search_path].present?
    end

    test "the books nav includes a Lists item" do
      item = Admin::DomainNav.config_for(:books)[:items].find { |i| i[:label] == "Lists" }
      assert item, "books nav is missing a Lists item"
      assert_equal "/admin/lists", item[:path]
    end
  end
end
