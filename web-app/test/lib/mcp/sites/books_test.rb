require "test_helper"

module Mcp
  module Sites
    class BooksTest < ActiveSupport::TestCase
      METHODOLOGY_URI = "greatest://books/ranking-methodology"

      def usage_text
        prompt = Mcp::Sites::Books.prompts(:public).find { |candidate| candidate.name_value == "usage" }
        prompt.template({}, server_context: {}).messages.first.content.text
      end

      def admin_usage_text
        prompt = Mcp::Sites::Books.prompts(:admin).find { |candidate| candidate.name_value == "usage" }
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

      test "the public texts are the files under config/mcp/books" do
        texts = Rails.root.join("config/mcp/books")

        assert_equal texts.join("instructions.md").read.strip, Mcp::Sites::Books.instructions(:public)
        assert_equal texts.join("usage.md").read.strip, usage_text
        assert_equal [Mcp::Sites::Books::USAGE_PROMPT], Mcp::Sites::Books.prompts(:public)
      end

      test "the admin usage prompt is named usage and has its own text" do
        prompts = Mcp::Sites::Books.prompts(:admin)

        assert_equal ["usage"], prompts.map(&:name_value)
        assert_not_equal usage_text, admin_usage_text
        assert_equal Rails.root.join("config/mcp/books/admin_usage.md").read.strip, admin_usage_text
      end

      test "the admin usage text states the protocol for destructive tools" do
        text = admin_usage_text

        ["dry-run", "dry_run", "show the user", "only then", "permanent", "ids", "search_admin_", "merged", "failed", "not_attempted",
          "warnings", "null"].each do |phrase|
          assert_includes text, phrase
        end
        assert_not_includes text.downcase, "cloudflare"
      end

      test "the admin usage text says an untag has no dry run" do
        text = admin_usage_text

        assert_match(/untag_book.*untag_author.*no dry run|no dry run.*untag/m, text)
      end

      test "the admin instructions are one paragraph that mentions dry-running first" do
        text = Mcp::Sites::Books.instructions(:admin)

        assert_not_includes text, "\n"
        assert_includes text, "dry-run"
        assert_includes text, "show the user"
        assert_equal Rails.root.join("config/mcp/books/admin_instructions.md").read.strip, text
      end

      test "the admin document serves the methodology resource and no composites" do
        assert_equal [Mcp::Sites::Books::RankingMethodology], Mcp::Sites::Books.resources(:admin)
        assert_equal [], Mcp::Sites::Books.composites(:admin)
      end

      test "an unknown document has nothing" do
        assert_nil Mcp::Sites::Books.instructions(:other)
        assert_equal [], Mcp::Sites::Books.prompts(:other)
        assert_equal [], Mcp::Sites::Books.resources(:other)
        assert_equal [], Mcp::Sites::Books.composites(:other)
      end
    end
  end
end
