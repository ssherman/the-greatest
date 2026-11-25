# frozen_string_literal: true

module Services
  module Books
    module BookSubmissions
      module Lookups
        # What one source said about a book. Titles and names are outside
        # text, so they are squished and capped on the way in (the limits the
        # submission itself carries).
        Answer = Data.define(:title, :subtitle, :author_names, :year) do
          def self.build(title:, author_names:, subtitle: nil, year: nil)
            new(
              title: Names.text(title),
              subtitle: Names.text(subtitle),
              author_names: Array(author_names).filter_map { |name| Names.text(name) }.uniq.first(::Books::BookSubmission::MAX_AUTHORS),
              year: Names.year(year)
            )
          end

          # A title and at least one author: without both nothing can be
          # searched for or created.
          def usable? = title.present? && author_names.any?
        end
      end
    end
  end
end
