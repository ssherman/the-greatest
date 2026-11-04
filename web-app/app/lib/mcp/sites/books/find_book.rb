# frozen_string_literal: true

module Mcp
  module Sites
    module Books
      # "Tell me about War and Peace" in one call (spec D13): the top search hit,
      # its record, and the lists that include it, from three dispatches.
      class FindBook < ::Mcp::Composite
        LISTS_LIMIT = 100

        operations "searchBooks", "getBook", "listBookLists"

        def self.tool_name = "find_book"

        def self.title = "Find a book"

        def self.description
          "Finds one book by title and returns it together with the lists that include it, in one call. " \
            "The book is the best search match for the title; the result has `book`, `lists` (up to " \
            "#{LISTS_LIMIT}, with the book's position on each) and `lists_total_count`. When the title is " \
            "ambiguous, use search_books and choose among the matches instead."
        end

        def self.input_schema
          {
            "type" => "object",
            "properties" => {
              "title" => {"type" => "string", "description" => "The book's title, as a person would type it. Add the author's name to narrow a common title."}
            },
            "required" => ["title"],
            "additionalProperties" => false
          }
        end

        def self.run(catalog, args, principal:, request:)
          call = ->(operation_id, arguments) { dispatch(catalog, operation_id, arguments, principal: principal, request: request) }
          title = args[:title].to_s

          found = call.call("searchBooks", {q: title, limit: 1})
          return ::Mcp::ToolResult.from(found) unless success?(found)

          slug = Array(found.body&.dig("data")).first&.dig("slug")
          return ::Mcp::ToolResult.error({"code" => "not_found", "detail" => "No book matches \"#{title}\""}) if slug.nil?

          book = call.call("getBook", {slug: slug})
          return ::Mcp::ToolResult.from(book) unless success?(book)

          lists = call.call("listBookLists", {slug: slug, limit: LISTS_LIMIT})
          return ::Mcp::ToolResult.from(lists) unless success?(lists)

          ::Mcp::ToolResult.from(
            ::Mcp::Dispatcher::Response.new(status: 200, body: {
              "book" => book.body["data"],
              "lists" => lists.body["data"],
              "lists_total_count" => lists.body.dig("meta", "total_count")
            })
          )
        end

        def self.success?(response) = (200..299).cover?(response.status)
        private_class_method :success?
      end
    end
  end
end
