# frozen_string_literal: true

module Services
  module Books
    module BookSubmissions
      module Lookups
        # Open Library by ISBN-13: the identifier names the work, the work
        # names the title and authors. Hits on two different works are
        # ambiguous, and an ambiguous answer would create a wrong book.
        module OpenLibrary
          module_function

          def call(isbn13)
            client = ::Books::OpenLibrary::Client.new
            keys = client.identifier("isbn13", isbn13).filter_map(&:work_key).uniq
            return nil unless keys.one?

            work = client.work(keys.first)
            answer = Answer.build(title: work.title, subtitle: work.subtitle, author_names: work.author_names)
            answer if answer.usable?
          rescue ::Books::OpenLibrary::Exceptions::NotFoundError
            nil
          end
        end
      end
    end
  end
end
