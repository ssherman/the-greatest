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

        # A whole series ("the complete series"), a run of books ("books 2-4",
        # "book 1 to 3") or a count of them ("7-book") names a set too; one
        # numbered book ("book 1 of the series") does not.
        SET_WORDS = /\b(box(ed)?[\s-]?set|collection|omnibus|trilogy|volumes|books 1|complete series|books? \d+\s*(-|–|to|through|\s)\s*\d+|\d+[\s-]books?)\b/i
        YEAR_SLACK = 1

        def agrees?(book, work, edition)
          title_agrees?(book, work, edition) && year_ok?(book, edition.publish_year)
        end

        def year_ok?(book, year)
          year.nil? || book.first_published_year.nil? || year.to_i >= book.first_published_year - YEAR_SLACK
        end

        def title_agrees?(book, work, edition)
          full, short = Check.their_title_keys(edition)
          return false if full.nil?

          ours_full, ours_short = our_titles(book, work)
          return true if ours_full.include?(full)
          return !full.delete_prefix(short).match?(SET_WORDS) if short && ours_full.include?(short)

          # Our title carries a subtitle the edition lacks: nothing was dropped from the edition.
          ours_short.include?(full)
        end

        # [full keys, short keys]. A volume parenthetical on our title gives no
        # short key, so it agrees only with the same volume.
        def our_titles(book, work)
          forms = ([book.title] + Array(book.alternate_titles)).map { |title| Check.title_forms(title) }.reject { |full, _| full.nil? }
          fulls = forms.map(&:first)
          # Only the work's full title: its short form would drop a subtitle from both sides.
          work_full = Check.their_title_keys(work).first if work
          fulls << work_full if work_full
          [fulls.uniq, forms.filter_map(&:last).uniq]
        end
      end
    end
  end
end
