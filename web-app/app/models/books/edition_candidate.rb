module Books
  # An Open Library edition of a book's work whose title does not agree with
  # the book: a translation, box set or alternate title. Kept for a later AI
  # check (spec section 3); never read by the finders.
  class EditionCandidate < ApplicationRecord
    belongs_to :book, class_name: "Books::Book"

    validates :edition_key, presence: true
  end
end
