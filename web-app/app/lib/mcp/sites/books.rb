# frozen_string_literal: true

module Mcp
  module Sites
    # The books site's part of /api/mcp (spec D13, D14): the find_book composite,
    # the `usage` prompt, the ranking-methodology resource and the server
    # instructions. The texts are Markdown files under config/mcp/books, read
    # once when this file loads. Only the public document has any of it until the
    # admin endpoint arrives.
    module Books
      TEXTS = ::Rails.root.join("config/mcp/books")
      INSTRUCTIONS = TEXTS.join("instructions.md").read.strip.freeze
      USAGE = TEXTS.join("usage.md").read.strip.freeze
      METHODOLOGY = TEXTS.join("ranking_methodology.md").read.freeze

      METHODOLOGY_URI = "greatest://books/ranking-methodology"

      USAGE_PROMPT = ::MCP::Prompt.define(
        name: "usage",
        title: "Using The Greatest Books tools",
        description: "How to answer from these tools: cite each book's url, keep rank order, " \
          "report total_count, and never invent a rank."
      ) do |_arguments, server_context: nil|
        ::MCP::Prompt::Result.new(
          description: "How to use The Greatest Books tools",
          messages: [::MCP::Prompt::Message.new(role: "user", content: ::MCP::Content::Text.new(USAGE))]
        )
      end

      class RankingMethodology < ::MCP::Resource
        uri METHODOLOGY_URI
        resource_name "ranking-methodology"
        title "How the ranking works"
        description "How lists are weighted into the ranking, what a ranking configuration is and what rank means."
        mime_type "text/markdown"

        def self.contents(server_context: nil)
          ::MCP::Resource::TextContents.new(text: METHODOLOGY, uri: uri, mime_type: mime_type)
        end
      end

      def self.instructions(document) = (INSTRUCTIONS if document == :public)

      def self.prompts(document) = (document == :public) ? [USAGE_PROMPT] : []

      def self.resources(document) = (document == :public) ? [RankingMethodology] : []

      def self.composites(document) = (document == :public) ? [::Mcp::Sites::Books::FindBook] : []
    end
  end
end
