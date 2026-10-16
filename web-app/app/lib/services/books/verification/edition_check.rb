# frozen_string_literal: true

module Services
  module Books
    module Verification
      # Spec section 2, stage 2: does an Open Library edition of the settled
      # work agree with the book? Its title must agree with one of our titles
      # or the work's (Check's rule); a subtitle dropped from the edition to
      # get there must not name a set; and it cannot predate the work.
      module EditionCheck
        module_function

        SET_WORDS = /\b(box(ed)?[\s-]?set|collection|omnibus|trilogy|volumes|books 1)\b/i
        YEAR_SLACK = 1

        def agrees?(book, work, edition)
          title_agrees?(book, work, edition) && year_ok?(book, edition.publish_year)
        end

        def year_ok?(book, year)
          year.nil? || book.first_published_year.nil? || year.to_i >= book.first_published_year - YEAR_SLACK
        end

        def title_agrees?(book, work, edition)
          full, short = Check.their_titles(edition)
          return false if full.nil?

          ours = our_titles(book, work)
          return true if ours.include?(full)
          return !full.delete_prefix(short).match?(SET_WORDS) if short && ours.include?(short)

          # Our title carries a subtitle the edition lacks: nothing was dropped from the edition.
          ours.filter_map { |title| Check.short(title) }.include?(full)
        end

        def our_titles(book, work)
          titles = ([book.title] + Array(book.alternate_titles)).filter_map { |title| Check.normalize(title) }
          # Only the work's full title: its short form would drop a subtitle from both sides.
          work_full = Check.their_titles(work).first if work
          titles << work_full if work_full
          titles.uniq
        end
      end
    end
  end
end
