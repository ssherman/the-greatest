# frozen_string_literal: true

module Services
  module Books
    module WorldCat
      # One book plus its WorldCat records -> category links, through the reviewed
      # map (docs/superpowers/specs/2026-10-11-worldcat-data-service-design.md, "Backfill").
      # Additive and idempotent; nothing is created or unlinked.
      class ApplyCategories
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        MIN_SUPPORT = 2

        def self.call(book:, records:, map:)
          new(book:, records:, map:).call
        end

        def initialize(book:, records:, map:)
          @book = book
          @records = without_merged_duplicates(records.uniq(&:oclc))
          @map = map
        end

        def call
          genre_support = Hash.new(0)
          subject_support = Hash.new(0)
          @records.each do |record|
            genre = record.genre.present? && @map.genre_for(record.genre)
            genre_support[genre] += 1 if genre
            phrases = ([record.genre] + record.subjects).compact.filter_map { |term| @map.subject_for(term) }.uniq
            phrases.each { |phrase| subject_support[phrase] += 1 }
          end

          genres_linked = []
          subjects_linked = []
          unresolved = []
          already = 0
          type_conflicts = 0

          supported(genre_support).sort_by { |name| [-genre_support[name], name] }.each do |name|
            category = ::Books::Category.active.genre.by_name(name).first
            next unless category

            # A book is Fiction or Nonfiction, never both: WorldCat disagreeing with a
            # type the book already holds is a conflict to count, not to resolve.
            if type_conflict?(category)
              type_conflicts += 1
              next
            end

            created = link(category)
            created ? genres_linked << category.name : already += 1
          end
          supported(subject_support).each do |phrase|
            category = ::Books::Category.active.subject.by_name(phrase).first ||
              ::Books::Category.active.subject.by_alternative_name(phrase).first
            if category.nil?
              unresolved << phrase
              next
            end
            created = link(category)
            created ? subjects_linked << category.name : already += 1
          end

          Result.new(success?: true, errors: [], data: {
            records: @records.size, genres_linked: genres_linked.sort, subjects_linked: subjects_linked.sort,
            subjects_unresolved: unresolved.sort, already_linked: already, type_conflicts: type_conflicts
          })
        end

        private

        # A later pass redirected an older OCLC number into a newer record; both come
        # back from the lookup, but they are one edition and must count once.
        def without_merged_duplicates(records)
          merged = records.flat_map(&:merged_oclc).to_set
          records.reject { |record| merged.include?(record.oclc) }
        end

        def type_conflict?(category)
          return false unless ::Books::Book::BOOK_TYPE_CATEGORY_NAMES.include?(category.name)

          other = (::Books::Book::BOOK_TYPE_CATEGORY_NAMES - [category.name])
          @book.categories.active.genre.exists?(name: other)
        end

        def supported(support)
          threshold = (@records.size == 1) ? 1 : MIN_SUPPORT
          support.select { |_name, n| n >= threshold }.keys
        end

        # @return [Boolean] true when a new link was made
        def link(category)
          item = ::CategoryItem.find_or_create_by!(category: category, item: @book)
          item.previously_new_record?
        end
      end
    end
  end
end
