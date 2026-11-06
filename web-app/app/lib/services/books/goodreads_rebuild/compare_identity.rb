# frozen_string_literal: true

module Services
  module Books
    module GoodreadsRebuild
      # Does our book still say what the export rows say it is (rebuild spec
      # §4)? Compared against the main edition group, the one with the most
      # rows:
      # - title_agrees: our full title (with subtitle) equals one of the
      #   group's export titles, normalized. Exact on purpose: legacy stored
      #   "X Men" for "X-Men: The Age of Apocalypse, Vol. 2", and the
      #   verification Check would let that drop its subtitle and agree.
      # - authors_agree: one of our authors is one of the group's export
      #   authors (Check.authors_agree?). A book with no authors disagrees.
      # - wrong_book: no group agrees with us even loosely, on title
      #   (title stems: a dropped subtitle allowed) or on authors. The
      #   record is a different book from everything imported onto it.
      module CompareIdentity
        module_function

        WorkLike = ::Services::Books::Verification::WorldCatCheck::WorkLike

        def call(book:, groups:, editions_by_id:)
          return {title_agrees: nil, authors_agree: nil, wrong_book: false} if groups.empty?

          editions = groups.map { |group| group["edition_ids"].filter_map { |id| editions_by_id[id] } }
          {
            title_agrees: exact_title?(book, editions.first),
            authors_agree: authors?(book, editions.first),
            wrong_book: editions.none? { |members| loose_title?(book, members) || authors?(book, members) }
          }
        end

        # Our title alone counts too: an export without the subtitle we hold has
        # stripped nothing. An export longer than ours still disagrees.
        def exact_title?(book, editions)
          ours = ([[book.title, book.subtitle].compact_blank.join(": "), book.title] + Array(book.alternate_titles))
            .filter_map { |title| check.title_key(title) }
          editions.any? { |edition| ours.include?(check.title_key(edition.title)) }
        end

        # Title stems: the full title and the text before its first ":" or
        # "(", on both sides. Not Check.titles_agree?, which rightly keeps a
        # subtitle naming a volume ("Book", "Vol.") when matching works, but
        # here would call "An Unexpected Cookbook" a different book from
        # "An Unexpected Cookbook: The Unofficial Book of Hobbit Cookery".
        def loose_title?(book, editions)
          ours = ([book.title, [book.title, book.subtitle].compact_blank.join(": ")] + Array(book.alternate_titles))
            .flat_map { |title| stems(title) }
          editions.any? { |edition| ours.intersect?(stems(edition.title)) }
        end

        # Letters-only forms too: legacy's titleize split run-together words
        # ("JoJo's" to "Jo Jo's", "iPhone" to "I Phone").
        def stems(title)
          texts = [title, title.to_s.split(/[:(]/).first]
          (texts.filter_map { |text| check.title_key(text) } + texts.filter_map { |text| check.compact(text) }).uniq
        end

        def authors?(book, editions)
          return false if book.authors.empty?

          names = editions.flat_map { |edition| [edition.primary_author, *Array(edition.additional_authors)] }.compact_blank.uniq
          check.authors_agree?(book, WorkLike.new(title: nil, subtitle: nil, author_names: names, author_keys: []))
        end

        def check = ::Services::Books::Verification::Check
      end
    end
  end
end
