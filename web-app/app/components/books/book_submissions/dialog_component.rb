# frozen_string_literal: true

# "Add a book that isn't on the site": a native <dialog> the owner of a books
# list opens from the add-item dropdown or from a strip row's Try another way.
# The reader picks one way and only that way's inputs are enabled, so the rest
# are not sent (the server refuses more than one). The answers land in
# #book-submission-errors, #book-submission-hits and the strip frame as Turbo
# Streams; books--book-submission-dialog does the rest in the browser.
class Books::BookSubmissions::DialogComponent < ViewComponent::Base
  METHODS = [
    ["goodreads", "Goodreads link"],
    ["amazon", "Amazon link"],
    ["isbn", "ISBN"],
    ["title_authors", "Title and author"]
  ].freeze
  DEFAULT_METHOD = "goodreads"

  def initialize(list:)
    @list = list
  end

  private

  attr_reader :list

  def selected?(method) = method == DEFAULT_METHOD

  # Hidden and disabled together: a disabled input is not submitted and the
  # hidden group is not in the way.
  def group_hidden?(method) = !selected?(method)

  def max_length = ::Books::BookSubmission::MAX_LENGTH

  def max_link_length = 2048
end
