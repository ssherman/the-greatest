# frozen_string_literal: true

module Mcp
  module Sites
    # The books site's part of /api/mcp and /api/mcp/admin (spec D13, D14): the
    # find_book composite (public only), each document's own `usage` prompt and
    # server instructions, and the ranking-methodology resource, which both
    # documents serve. The texts are Markdown files under config/mcp/books, read
    # once when this file loads.
    module Books
      TEXTS = ::Rails.root.join("config/mcp/books")
      INSTRUCTIONS = TEXTS.join("instructions.md").read.strip.freeze
      USAGE = TEXTS.join("usage.md").read.strip.freeze
      ADMIN_INSTRUCTIONS = TEXTS.join("admin_instructions.md").read.strip.freeze
      ADMIN_USAGE = TEXTS.join("admin_usage.md").read.strip.freeze
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

      ADMIN_USAGE_PROMPT = ::MCP::Prompt.define(
        name: "usage",
        title: "Using The Greatest Books admin tools",
        description: "How to use the admin tools safely: take ids from the search tools, dry-run every merge " \
          "and delete, show the user, and run it only after they agree."
      ) do |_arguments, server_context: nil|
        ::MCP::Prompt::Result.new(
          description: "How to use The Greatest Books admin tools",
          messages: [::MCP::Prompt::Message.new(role: "user", content: ::MCP::Content::Text.new(ADMIN_USAGE))]
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

      def self.instructions(document)
        case document
        when :public then INSTRUCTIONS
        when :admin then ADMIN_INSTRUCTIONS
        end
      end

      def self.prompts(document)
        case document
        when :public then [USAGE_PROMPT]
        when :admin then [ADMIN_USAGE_PROMPT]
        else []
        end
      end

      def self.resources(document) = [:public, :admin].include?(document) ? [RankingMethodology] : []

      # find_book's operations are public ones, not in the admin catalogue.
      def self.composites(document) = (document == :public) ? [::Mcp::Sites::Books::FindBook] : []
    end
  end
end
