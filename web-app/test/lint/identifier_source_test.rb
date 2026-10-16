# frozen_string_literal: true

require "test_helper"

# Identifier provenance spec, section 1: every books writer sets a source.
# A model validation would break 135 test call sites that build books
# identifiers by hand, so the rule is enforced on the app's write sites
# instead. A write is the statement starting at a matching line, up to
# its closing parenthesis; it must mention `source`, or the variable it
# assigns must have its `.source` set within WINDOW lines. Music and games
# code is not scanned.
class IdentifierSourceTest < ActiveSupport::TestCase
  ROOTS = %w[
    app/lib/books
    app/lib/data_importers/books
    app/lib/services/books
    app/lib/services/books_migration
    app/lib/services/identifiers
    lib/tasks
  ].freeze
  WRITE = /identifiers\.(create!?|find_or_create_by!?|find_or_initialize_by|build|new)\(|Identifier\.(create!?|find_or_create_by!?|insert_all|upsert_all|new)\(/
  WINDOW = 6

  test "every books identifier write names a source" do
    offenders = ROOTS.flat_map { |root| Dir[Rails.root.join(root, "**/*.{rb,rake}")] }.flat_map { |path| offenders_in(path) }

    assert_empty offenders, "books identifier writes with no source:\n#{offenders.join("\n")}"
  end

  test "the scan catches a write with no source" do
    file = Tempfile.new(["writer", ".rb"])
    file.write(<<~RUBY)
      book.identifiers.create!(identifier_type: :books_work_isbn13, value: "x")
      identifier = book.identifiers.find_or_initialize_by(identifier_type: :books_work_isbn10, value: "y")
      identifier.source = :legacy
    RUBY
    file.close

    assert_equal 1, offenders_in(file.path).size
  ensure
    file&.unlink
  end

  private

  def offenders_in(path)
    lines = File.readlines(path)
    lines.each_index.filter_map do |index|
      line = lines[index]
      next unless line.match?(WRITE)
      next if music_or_games?(path, line)
      next if statement(lines, index).include?("source")
      next if followed_by_source_assignment?(lines, index)

      "#{path.delete_prefix("#{Rails.root}/")}:#{index + 1}: #{line.strip}"
    end
  end

  # The write's own text: from its line until its parentheses balance, at
  # most WINDOW lines.
  def statement(lines, index)
    text = +""
    lines[index, WINDOW].each do |line|
      text << line
      break if text.count("(") <= text.count(")")
    end
    text
  end

  # `identifier = ...find_or_initialize_by(...)` followed by `identifier.source = ...`
  def followed_by_source_assignment?(lines, index)
    variable = lines[index][/\A\s*(\w+)\s*=/, 1]
    variable && lines[index + 1, WINDOW].to_a.any? { |line| line.include?("#{variable}.source") }
  end

  def music_or_games?(path, line)
    path.include?("/tasks/music") || path.include?("/tasks/games") || line.match?(/music_|games_/)
  end
end
