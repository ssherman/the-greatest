# frozen_string_literal: true

# The "Finding" cell of the repair verdicts index: what a verdict is about,
# so a reviewer need not open each one. Display only; the lookups arrive
# preloaded from the controller (one query per table for the whole page), so
# nothing here queries.
class Admin::Books::RepairVerdictRowComponent < ViewComponent::Base
  LABELS = {
    "merge_books" => "Merge", "fix_identity" => "Fix", "merge_authors" => "Merge authors",
    "relink" => "Relink", "strip_identifier" => "Strip identifier", "mark_provisional" => "Mark provisional"
  }.freeze

  # books and authors are id => record hashes; list_counts is book id => ListItem count.
  def initialize(verdict:, books: {}, authors: {}, list_counts: {})
    @verdict = verdict
    @books = books
    @authors = authors
    @list_counts = list_counts
  end

  private

  attr_reader :verdict, :books, :authors, :list_counts

  def payload = verdict.payload

  def label = LABELS.fetch(verdict.kind)

  # `"Title: Subtitle" by A, B (#id)`, or `#id (gone)` when the book is deleted.
  def book_ref(id, with_lists: false)
    book = books[id]
    return safe_join(["#", id.to_s, " (gone)"]) unless book

    title = [book.title, book.subtitle.presence].compact.join(": ")
    names = book.authors.first(2).map(&:name)
    text = names.any? ? "\"#{title}\" by #{names.join(", ")} " : "\"#{title}\" "
    note = with_lists ? list_note(id) : nil
    safe_join([text, link_to("(##{id})", admin_books_book_path(book), class: "link"), note && ", #{note}"].compact)
  end

  def author_ref(id)
    author = authors[id]
    return safe_join(["#", id.to_s, " (gone)"]) unless author

    safe_join(["\"#{author.name}\" ", link_to("(##{id})", admin_books_author_path(author), class: "link")])
  end

  def list_note(id)
    count = list_counts[id].to_i
    "on #{count} #{"list".pluralize(count)}" if count > 0
  end

  def export_authors = Array(payload["author_names"]).join(", ")

  def export_title = payload["full_title"].presence

  def book_title(id)
    book = books[id]
    book ? "\"#{book.title}\"" : "(gone)"
  end
end
