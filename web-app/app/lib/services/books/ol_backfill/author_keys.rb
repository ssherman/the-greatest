# frozen_string_literal: true

module Services
  module Books
    module OlBackfill
      # Spec section 2: our book's authors take the matched work's author
      # keys. Only an author with no key gets one; a different key is a
      # conflict left alone (Open Library has many duplicate authors), and a
      # key another author of ours holds is a pair for review.
      class AuthorKeys
        AUTHOR_KEY = "books_author_openlibrary_id"

        def self.call(book:, work:)
          new(book, work).call
        end

        def initialize(book, work)
          @book = book
          @work = work
        end

        def call
          changes = {"added" => [], "pairs" => [], "conflicts" => []}
          @book.authors.each do |author|
            key = key_for(author)
            next if key.nil?

            held = author.identifiers.where(identifier_type: AUTHOR_KEY).order(:id).pluck(:value)
            next if held.include?(key)

            if held.any?
              changes["conflicts"] << [author.id, held.first, key]
            elsif (other = holder_of(key, except: author))
              ::Services::DuplicateCandidates::Flag.call(
                item_type: "Books::Author", ids: [author.id, other], source: :ol_backfill,
                evidence: {reason: "Open Library gives both authors the key #{key}", open_library_key: key}
              )
              changes["pairs"] << [author.id, other, key]
            else
              author.identifiers.create!(identifier_type: AUTHOR_KEY, value: key)
              changes["added"] << [author.id, key]
            end
          end
          changes
        end

        private

        # The key of the one work author whose name agrees (initials folded,
        # Services::Text::PersonNameKey), or nil.
        def key_for(author)
          names = ::Services::Text::PersonNameKey.all([author.name, *Array(author.alternate_names)])
          names_on_work = Array(@work.author_names)
          keys_on_work = Array(@work.author_keys)
          keys = names_on_work.each_index.select { |index| names.include?(::Services::Text::PersonNameKey.call(names_on_work[index])) }
            .filter_map { |index| keys_on_work[index] }.uniq
          keys.first if keys.size == 1
        end

        def holder_of(key, except:)
          ::Identifier.where(identifiable_type: "Books::Author", identifier_type: AUTHOR_KEY, value: key)
            .where.not(identifiable_id: except.id).order(:identifiable_id).pick(:identifiable_id)
        end
      end
    end
  end
end
