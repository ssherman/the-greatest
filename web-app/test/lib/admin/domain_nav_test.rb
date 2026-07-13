require "test_helper"

module Admin
  class DomainNavTest < ActiveSupport::TestCase
    test "layout_for returns the domain admin layout" do
      assert_equal "music/admin", Admin::DomainNav.layout_for(:music)
      assert_equal "games/admin", Admin::DomainNav.layout_for(:games)
    end

    test "layout_for falls back to music for domains with no admin layout" do
      assert_equal "music/admin", Admin::DomainNav.layout_for(:books)
      assert_equal "music/admin", Admin::DomainNav.layout_for(:movies)
      assert_equal "music/admin", Admin::DomainNav.layout_for(nil)
    end

    test "every layout_for result names a template that exists" do
      [:music, :games, :books, :movies, nil].each do |domain|
        layout = Admin::DomainNav.layout_for(domain)
        assert File.exist?(Rails.root.join("app/views/layouts/#{layout}.html.erb")),
          "layout #{layout} for domain #{domain.inspect} does not exist"
      end
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
      [:music, :games].each do |domain|
        Admin::DomainNav.config_for(domain)[:items].each do |item|
          assert item[:label].present?, "#{domain} item missing label"
          assert item[:path].present?, "#{domain} item #{item[:label]} missing path"
          assert item[:icon].present?, "#{domain} item #{item[:label]} missing icon"
        end
      end
    end

    test "config_for returns nil for a domain with no admin" do
      assert_nil Admin::DomainNav.config_for(:books)
    end

    test "every domain in CONFIGS has a categories_search_path" do
      Admin::DomainNav::CONFIGS.each_key do |domain|
        assert Admin::DomainNav.config_for(domain)[:categories_search_path].present?,
          "#{domain} config is missing categories_search_path"
      end
    end
  end
end
