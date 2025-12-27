# frozen_string_literal: true

require "test_helper"

module Services
  module Html
    class SimplifierServiceTest < ActiveSupport::TestCase
      def test_call_class_method
        html = "<div>Test</div>"
        result = SimplifierService.call(html)

        assert_equal "<div>Test</div>", result
      end

      def test_returns_nil_for_blank_html
        assert_nil SimplifierService.call(nil)
        assert_nil SimplifierService.call("")
        assert_nil SimplifierService.call("   ")
      end

      def test_preserves_basic_semantic_structure
        html = <<~HTML
          <div class="list">
            <h2 id="title">Top Albums</h2>
            <ul>
              <li><span>Album 1</span></li>
              <li><a href="/album2">Album 2</a></li>
            </ul>
            <p>Some description</p>
          </div>
        HTML

        result = SimplifierService.call(html)

        # Should preserve the structure
        assert_includes result, '<div class="list">'
        assert_includes result, '<h2 id="title">Top Albums</h2>'
        assert_includes result, "<ul>"
        assert_includes result, "<li>"
        assert_includes result, "<span>Album 1</span>"
        assert_includes result, '<a href="/album2">Album 2</a>'
        assert_includes result, "<p>Some description</p>"
      end

      def test_removes_script_tags
        html = <<~HTML
          <div>
            <script>alert('bad');</script>
            <p>Good content</p>
          </div>
        HTML

        result = SimplifierService.call(html)

        refute_includes result, "<script>"
        refute_includes result, "alert"
        assert_includes result, "<p>Good content</p>"
      end

      def test_removes_style_tags
        html = <<~HTML
          <div>
            <style>body { color: red; }</style>
            <p>Content</p>
          </div>
        HTML

        result = SimplifierService.call(html)

        refute_includes result, "<style>"
        refute_includes result, "color: red"
        assert_includes result, "<p>Content</p>"
      end

      def test_removes_media_elements
        html = <<~HTML
          <div>
            <img src="album.jpg" alt="Album cover">
            <video src="video.mp4"></video>
            <p>Album: Dark Side of the Moon</p>
          </div>
        HTML

        result = SimplifierService.call(html)

        refute_includes result, "<img"
        refute_includes result, "<video"
        refute_includes result, "album.jpg"
        assert_includes result, "<p>Album: Dark Side of the Moon</p>"
      end

      def test_removes_interactive_elements
        html = <<~HTML
          <div>
            <button>Click me</button>
            <form><input type="text"></form>
            <p>1. The Beatles - Abbey Road</p>
          </div>
        HTML

        result = SimplifierService.call(html)

        refute_includes result, "<button"
        refute_includes result, "<form"
        refute_includes result, "<input"
        assert_includes result, "<p>1. The Beatles - Abbey Road</p>"
      end

      def test_preserves_table_elements
        html = <<~HTML
          <div>
            <table class="wikitable">
              <thead>
                <tr><th>Rank</th><th>Album</th><th>Artist</th></tr>
              </thead>
              <tbody>
                <tr><td>1</td><td>Abbey Road</td><td>Beatles</td></tr>
                <tr><td>2</td><td>Dark Side of the Moon</td><td>Pink Floyd</td></tr>
              </tbody>
            </table>
            <p>Best albums list</p>
          </div>
        HTML

        result = SimplifierService.call(html)

        # Should preserve table structure for Wikipedia-style lists
        assert_includes result, "<table"
        assert_includes result, "<thead"
        assert_includes result, "<tbody"
        assert_includes result, "<tr"
        assert_includes result, "<th"
        assert_includes result, "<td"
        assert_includes result, "Abbey Road"
        assert_includes result, "Beatles"
        assert_includes result, "Dark Side of the Moon"
        assert_includes result, "Pink Floyd"
        assert_includes result, "<p>Best albums list</p>"
        # Should preserve allowed attributes on table elements
        assert_includes result, 'class="wikitable"'
      end

      def test_removes_navigation_elements
        html = <<~HTML
          <div>
            <nav>Navigation menu</nav>
            <header>Page header</header>
            <aside>Sidebar</aside>
            <footer>Footer content</footer>
            <ul>
              <li>Album 1</li>
              <li>Album 2</li>
            </ul>
          </div>
        HTML

        result = SimplifierService.call(html)

        refute_includes result, "<nav"
        refute_includes result, "<header"
        refute_includes result, "<aside"
        refute_includes result, "<footer"
        # Should preserve the actual list
        assert_includes result, "<ul>"
        assert_includes result, "<li>Album 1</li>"
      end

      def test_removes_unwanted_attributes_but_keeps_essential_ones
        html = <<~HTML
          <div class="container" id="main" data-track="analytics" style="color: red;" onclick="bad()">
            <a href="/album" class="link" title="Album Link" data-id="123">
              <img src="cover.jpg" alt="Cover" width="100" height="100">
              Album Name
            </a>
          </div>
        HTML

        result = SimplifierService.call(html)

        # Should keep essential attributes
        assert_includes result, 'class="container"'
        assert_includes result, 'id="main"'
        assert_includes result, 'href="/album"'
        assert_includes result, 'class="link"'
        assert_includes result, 'title="Album Link"'

        # Should remove unwanted attributes
        refute_includes result, "data-track"
        refute_includes result, "style="
        refute_includes result, "onclick"
        refute_includes result, "data-id"
        refute_includes result, "width="
        refute_includes result, "height="

        # Should remove img tag entirely
        refute_includes result, "<img"
      end

      def test_handles_nested_unwanted_elements
        html = <<~HTML
          <div>
            <div class="content">
              <script>
                var data = { albums: ['test'] };
              </script>
              <div class="albums">
                <p>1. <strong>Abbey Road</strong> - The Beatles</p>
                <figure>
                  <img src="cover.jpg">
                  <figcaption>Album cover</figcaption>
                </figure>
              </div>
            </div>
          </div>
        HTML

        result = SimplifierService.call(html)

        # Should preserve good structure
        assert_includes result, '<div class="content">'
        assert_includes result, '<div class="albums">'
        assert_includes result, "<strong>Abbey Road</strong>"

        # Should remove all unwanted nested elements
        refute_includes result, "<script"
        refute_includes result, "<figure"
        refute_includes result, "<img"
        refute_includes result, "<figcaption"
        refute_includes result, "var data"
      end

      def test_preserves_text_content
        html = <<~HTML
          <div>
            <script>bad script</script>
            <p>1. The Dark Side of the Moon - Pink Floyd (1973)</p>
            <img src="cover.jpg" alt="Cover">
            <p>2. Abbey Road - The Beatles (1969)</p>
            <style>p { color: red; }</style>
          </div>
        HTML

        result = SimplifierService.call(html)

        # Should preserve all the actual list content
        assert_includes result, "1. The Dark Side of the Moon - Pink Floyd (1973)"
        assert_includes result, "2. Abbey Road - The Beatles (1969)"

        # Should remove unwanted elements
        refute_includes result, "bad script"
        refute_includes result, "<img"
        refute_includes result, "color: red"
      end

      def test_handles_malformed_html_gracefully
        html = "<div><p>Unclosed paragraph<script>alert('test')</div>"

        result = SimplifierService.call(html)

        # Nokogiri should handle malformed HTML gracefully
        assert_not_nil result
        refute_includes result, "<script"
        refute_includes result, "alert"
        assert_includes result, "Unclosed paragraph"
      end
    end
  end
end
