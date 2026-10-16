# frozen_string_literal: true

module Services
  module Books
    module Verification
      # Spec section 2, stage 3: a WorldCat record agrees with the book when
      # its title, its creator (or a contributor) and its year all agree. The
      # record is reshaped into what Check compares: WorldCat writes
      # "Title : subtitle" and "Last, First, 1828-1910." creators.
      module WorldCatCheck
        module_function

        WorkLike = Data.define(:title, :subtitle, :author_names, :author_keys)
        DATES = /,?\s*\d{4}\s*-\s*(\d{4})?\s*\.?\s*\z/
        PARENTHESES = /\s*\([^)]*\)/

        def agrees?(book, record)
          work = work_like(record)
          return false if work.title.blank? || work.author_names.empty?

          Check.titles_agree?(book, work) && Check.authors_agree?(book, work) && EditionCheck.year_ok?(book, record.year)
        end

        # Both title and creator disagree. A missing title or creator, or a
        # book with no authors, is unknown.
        def clearly_different?(book, record)
          work = work_like(record)
          return false if work.title.blank? || work.author_names.empty? || book.authors.empty?

          !Check.titles_agree?(book, work) && !Check.authors_agree?(book, work)
        end

        def work_like(record)
          title, _, subtitle = record.title.to_s.partition(" : ")
          title = title.sub(%r{\s*/\s*\z}, "").strip
          subtitle = record.subtitle.presence || subtitle.sub(%r{\s*/.*\z}, "").strip.presence
          WorkLike.new(title: title.presence, subtitle: subtitle, author_names: names(record), author_keys: [])
        end

        def names(record)
          raw = [record.creator, *Array(record.contributors)].map { |name| name.is_a?(Hash) ? name["name"] : name }
          raw.compact.flat_map { |name| variants(name.to_s) }.uniq
        end

        def variants(name)
          cleaned = name.gsub(PARENTHESES, "").sub(DATES, "").strip.chomp(",").chomp(".").strip
          return [] if cleaned.blank?

          last, comma, first = cleaned.partition(",")
          comma.empty? ? [cleaned] : [cleaned, "#{first.strip} #{last.strip}"]
        end
      end
    end
  end
end
