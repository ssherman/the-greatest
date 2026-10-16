# frozen_string_literal: true

require "test_helper"

# Identifier provenance spec, section 1: every books writer sets a source.
# A model validation would break 135 test call sites that build books
# identifiers by hand, so the rule is enforced on the app's write sites
# instead. Every Ruby file under app/ and lib/ is scanned except music,
# games and movies code. A line starting with "." continues the call on
# the line before it, so chained writes are read as one. A write is the
# statement starting at a matching line, up to its closing parenthesis; it
# must say `source:` or `.source =`, or the variable it assigns must have
# its `.source` set within WINDOW lines.
class IdentifierSourceTest < ActiveSupport::TestCase
  ROOTS = %w[app/**/*.rb lib/**/*.{rb,rake}].freeze
  EXEMPT_PATH = %r{/(music|games|movies)/}
  EXEMPT_LINE = /music_|games_|movies_/
  # The line names identifiers ...
  CONTEXT = /\bIdentifier\b|\.identifiers\b/
  # ... and calls something that writes one.
  WRITE = /\.(create!?|find_or_create_by!?|find_or_initialize_by|build|new|create_with|first_or_create!?|first_or_initialize|insert_all!?|upsert_all|insert!?|upsert)\(/
  NAMES_SOURCE = /\bsource:|\.source\s*=/
  WINDOW = 6

  test "every books identifier write names a source" do
    offenders = scanned_paths.flat_map { |path| offenders_in(path) }

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

  test "the scan catches chained writes and the other write shapes" do
    file = Tempfile.new(["writer", ".rb"])
    file.write(<<~RUBY)
      edition.identifiers
        .find_or_initialize_by(identifier_type: :books_edition_asin, value: "x")
        .save!
      Identifier.where(value: "y").first_or_create!(identifier_type: :books_work_isbn13)
      book.identifiers.create_with(value: "z").find_or_create_by!(identifier_type: :books_work_isbn10)
      Identifier.insert({identifiable_type: "Books::Book", value: "w"})
      Identifier.upsert_all(rows, unique_by: :index_identifiers_on_lookup_unique)
    RUBY
    file.close

    assert_equal [1, 4, 5, 6, 7], offenders_in(file.path).map { |line| line[/:(\d+):/, 1].to_i }
  ensure
    file&.unlink
  end

  test "a word merely containing source does not excuse a write" do
    file = Tempfile.new(["writer", ".rb"])
    file.write(%(source_book.identifiers.create!(identifier_type: :books_work_isbn13, value: resource)\n))
    file.close

    assert_equal 1, offenders_in(file.path).size
  ensure
    file&.unlink
  end

  test "the scan covers all of app and lib, skipping music, games and movies" do
    assert_includes scanned_paths, Rails.root.join("app/lib/services/books/amazon_edition_upserter.rb").to_s
    assert_includes scanned_paths, Rails.root.join("lib/tasks/e2e.rake").to_s
    assert scanned_paths.none? { |path| path.match?(EXEMPT_PATH) }
    assert scanned_paths.any? { |path| path.include?("/app/sidekiq/") }
  end

  private

  def scanned_paths
    @scanned_paths ||= ROOTS.flat_map { |glob| Dir[Rails.root.join(glob)] }.reject { |path| path.match?(EXEMPT_PATH) }
  end

  def offenders_in(path)
    lines = logical_lines(path)
    lines.each_index.filter_map do |index|
      number, text = lines[index]
      next unless text.match?(CONTEXT) && text.match?(WRITE)
      next if text.match?(EXEMPT_LINE)
      next if statement(lines, index).match?(NAMES_SOURCE)
      next if followed_by_source_assignment?(lines, index)

      "#{path.delete_prefix("#{Rails.root}/")}:#{number}: #{text.strip}"
    end
  end

  # [line number, text] per logical line: a line starting with "." is
  # joined onto the one before it.
  def logical_lines(path)
    File.readlines(path).each_with_index.each_with_object([]) do |(line, index), lines|
      if line.lstrip.start_with?(".") && lines.any?
        lines.last[1] = "#{lines.last[1].chomp}#{line.strip}\n"
      else
        lines << [index + 1, line]
      end
    end
  end

  # The write's own text: from its line until its parentheses balance, at
  # most WINDOW lines.
  def statement(lines, index)
    text = +""
    lines[index, WINDOW].each do |_number, line|
      text << line
      break if text.count("(") <= text.count(")")
    end
    text
  end

  # `identifier = ...find_or_initialize_by(...)` followed by `identifier.source = ...`
  def followed_by_source_assignment?(lines, index)
    variable = lines[index][1][/\A\s*(\w+)\s*=/, 1]
    variable && lines[index + 1, WINDOW].to_a.any? { |_number, line| line.match?(/\b#{variable}\.source\s*=/) }
  end
end
