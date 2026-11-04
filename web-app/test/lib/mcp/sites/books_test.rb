require "test_helper"

module Mcp
  module Sites
    class BooksTest < ActiveSupport::TestCase
      METHODOLOGY_URI = "greatest://books/ranking-methodology"

      def usage_text
        prompt = Mcp::Sites::Books.prompts(:public).find { |candidate| candidate.name_value == "usage" }
        prompt.template({}, server_context: {}).messages.first.content.text
      end

      def methodology
        Mcp::Sites::Books.resources(:public).find { |resource| resource.uri == METHODOLOGY_URI }
      end

      test "the registry serves books" do
        assert_equal Mcp::Sites::Books, Mcp::Sites.for(:books)
      end

      test "the public document has the find_book composite" do
        assert_equal [Mcp::Sites::Books::FindBook], Mcp::Sites::Books.composites(:public)
      end

      test "the usage prompt states each rule" do
        text = usage_text.downcase

        ["cite", "url", "rank order", "total_count", "never invent a rank"].each do |phrase|
          assert_includes text, phrase
        end
      end

      test "the methodology resource has its URI, name and markdown type" do
        assert_equal METHODOLOGY_URI, methodology.uri
        assert_equal "ranking-methodology", methodology.name_value
        assert_equal "text/markdown", methodology.mime_type
      end

      test "the methodology is 300 to 600 words of prose" do
        text = methodology.contents.text

        assert_includes 300..600, text.split.size
        assert_equal METHODOLOGY_URI, methodology.contents.uri
      end

      test "the instructions are one paragraph that mentions citing url" do
        text = Mcp::Sites::Books.instructions(:public)

        assert_not_includes text, "\n\n"
        assert_includes text, "url"
        assert_includes text.downcase, "cite"
      end

      test "any other document has nothing until increment 2" do
        assert_nil Mcp::Sites::Books.instructions(:admin)
        assert_equal [], Mcp::Sites::Books.prompts(:admin)
        assert_equal [], Mcp::Sites::Books.resources(:admin)
        assert_equal [], Mcp::Sites::Books.composites(:admin)
      end
    end
  end
end
