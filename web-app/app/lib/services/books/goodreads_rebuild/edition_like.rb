# frozen_string_literal: true

module Services
  module Books
    module GoodreadsRebuild
      # A Goodreads export edition shaped like a book, for the verification
      # Check: it reads title, alternate_titles and authors (name,
      # alternate_names, id).
      module EditionLike
        Book = Data.define(:title, :alternate_titles, :authors, :first_published_year)
        Author = Data.define(:name, :alternate_names, :id)

        def self.from(edition)
          names = [edition.primary_author, *Array(edition.additional_authors)].compact_blank.uniq
          Book.new(title: edition.title, alternate_titles: [], first_published_year: edition.original_publication_year,
            authors: names.map { |name| Author.new(name: name, alternate_names: [], id: nil) })
        end
      end
    end
  end
end
