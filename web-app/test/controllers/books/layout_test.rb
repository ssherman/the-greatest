require "test_helper"

module Books
  class LayoutTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev-new.thegreatestbooks.org"
    end

    # The nav links partial is rendered twice -- once in the desktop bar, once
    # in the drawer panel. A plain assert_select passes when one copy is
    # missing, which is exactly the edit this guards against.
    test "nav links render in both the desktop bar and the drawer panel" do
      get "/"

      assert_response :success
      assert_select ".navbar-center a[href=?]", "/authors", count: 1
      assert_select "#books-nav-drawer-panel a[href=?]", "/authors", count: 1
    end

    test "the My Books menu links to recommendations in both nav variants" do
      get "/"

      assert_response :success
      assert_select ".navbar-center #navbar_my_books a[href='/recommendations']", count: 1
      assert_select "#books-nav-drawer-panel #navbar_my_books a[href='/recommendations']", count: 1
    end

    test "the drawer panel links home from its header" do
      get "/"

      assert_response :success
      assert_select "#books-nav-drawer-panel header a[href=?]", "/", count: 1
    end

    # Exactly one link marked, and only in the drawer: the bar renders the same
    # partial, so a mark leaking into it would announce two current pages.
    test "the current page is marked once, in the drawer only" do
      get "/authors"

      assert_response :success
      assert_select "#books-nav-drawer-panel a[aria-current='page']", count: 1
      assert_select "#books-nav-drawer-panel a[aria-current='page'][href=?]", "/authors", count: 1
      assert_select ".navbar-center a[aria-current]", count: 0
    end

    # A marked link inside a collapsed submenu would be invisible. The bar must
    # stay collapsed: `open` there would drop its floating dropdown over the page.
    test "the drawer's Lists submenu starts open on a page it contains" do
      get "/lists"

      assert_response :success
      assert_select "#books-nav-drawer-panel details[open]", count: 1
      assert_select ".navbar-center details[open]", count: 0
    end

    test "the drawer's Lists submenu starts closed elsewhere" do
      get "/authors"

      assert_response :success
      assert_select "#books-nav-drawer-panel details[open]", count: 0
    end

    test "the drawer panel is a sibling of the drawer content, not inside it" do
      get "/"

      assert_select "div.drawer > div.drawer-content"
      assert_select "div.drawer > div.drawer-side #books-nav-drawer-panel"
      assert_select "div.drawer-content #books-nav-drawer-panel", count: 0
    end

    test "the hamburger is a label pointing at the drawer toggle" do
      get "/"

      assert_select "#books-nav-drawer-button[for=?]", "books-nav-drawer"
      assert_select "input#books-nav-drawer[type=?]", "checkbox"
    end

    # The overlay label is the only way to close the drawer without JavaScript.
    test "the drawer has an overlay label that closes it" do
      get "/"

      assert_select ".drawer-side label.drawer-overlay[for=?]", "books-nav-drawer"
    end
  end
end
