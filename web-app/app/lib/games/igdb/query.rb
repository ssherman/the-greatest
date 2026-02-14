# frozen_string_literal: true

module Games
  module Igdb
    class Query
      def initialize(clauses = {})
        @clauses = clauses.freeze
      end

      def fields(*names)
        self.class.new(@clauses.merge(fields: names.map(&:to_s).join(", ")))
      end

      def fields_all
        self.class.new(@clauses.merge(fields: "*"))
      end

      def exclude(*names)
        self.class.new(@clauses.merge(exclude: names.map(&:to_s).join(", ")))
      end

      def where(conditions)
        existing = @clauses[:where] || []

        clause = case conditions
        when String
          conditions
        when Hash
          conditions.map { |field, value| format_where_condition(field, value) }.join(" & ")
        else
          raise Exceptions::QueryError, "where expects a String or Hash"
        end

        self.class.new(@clauses.merge(where: existing + [clause]))
      end

      def search(term)
        self.class.new(@clauses.merge(search: term))
      end

      def sort(field, direction = :asc)
        self.class.new(@clauses.merge(sort: "#{field} #{direction}"))
      end

      def limit(n)
        unless n.is_a?(Integer) && n >= 1 && n <= 500
          raise Exceptions::QueryError, "Limit must be between 1 and 500"
        end
        self.class.new(@clauses.merge(limit: n))
      end

      def offset(n)
        unless n.is_a?(Integer) && n >= 0
          raise Exceptions::QueryError, "Offset must be non-negative"
        end
        self.class.new(@clauses.merge(offset: n))
      end

      def to_s
        if @clauses.empty?
          raise Exceptions::QueryError, "Query must have at least one clause"
        end

        parts = []
        parts << "fields #{@clauses[:fields]};" if @clauses[:fields]
        parts << "exclude #{@clauses[:exclude]};" if @clauses[:exclude]
        parts << "search \"#{escape_search_term(@clauses[:search])}\";" if @clauses[:search]

        if @clauses[:where]&.any?
          parts << "where #{@clauses[:where].join(" & ")};"
        end

        parts << "sort #{@clauses[:sort]};" if @clauses[:sort]
        parts << "limit #{@clauses[:limit]};" if @clauses[:limit]
        parts << "offset #{@clauses[:offset]};" if @clauses[:offset]
        parts.join(" ")
      end

      private

      def format_where_condition(field, value)
        case value
        when Array
          "#{field} = (#{value.join(",")})"
        when nil
          "#{field} = null"
        else
          "#{field} = #{value}"
        end
      end

      def escape_search_term(term)
        # Escape backslashes first, then quotes for Apicalypse query syntax
        term.to_s.gsub("\\", "\\\\\\\\").gsub('"', '\\"')
      end
    end
  end
end
