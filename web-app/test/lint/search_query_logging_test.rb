# frozen_string_literal: true

require "test_helper"

# query_definition carries the visitor's search text. Production logs at info,
# so logging it at info or above writes every search into the server logs.
# Debug is fine: it is off in production.
class SearchQueryLoggingTest < ActiveSupport::TestCase
  SEARCH_FILES = Dir[Rails.root.join("app/lib/search/**/*.rb")]

  test "no search class logs a query definition above debug" do
    offending = SEARCH_FILES.flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, index|
        next unless line.include?("query_definition") && line.match?(/logger\.(?:info|warn|error|fatal|unknown)\b/)
        "#{Pathname(path).relative_path_from(Rails.root)}:#{index + 1}: #{line.strip}"
      end
    end

    assert_empty offending
  end

  # Guards the test above against passing vacuously (an empty glob, or the
  # lines removed rather than lowered).
  test "the search classes still log their query definitions at debug" do
    debug_lines = SEARCH_FILES.sum do |path|
      File.readlines(path).count { |line| line.include?("query_definition") && line.include?("logger.debug") }
    end

    assert_operator debug_lines, :>=, 11
  end
end
