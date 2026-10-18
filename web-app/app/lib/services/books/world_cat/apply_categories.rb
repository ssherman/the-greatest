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
        # A term also has to be on this share of the records that carry any mapped term
        # of its kind. Two records are enough support for a book with a handful of
        # editions, but a classic has dozens, and the rehearsal (2026-10-12) showed its
        # study editions handing Animal Farm "Textbooks", its children's imprints handing
        # Little Women "Children's books" and a comic adaptation handing Dune "Comics &
        # Graphic Novels", each on two or three of thirty records. A quarter keeps a real
        # secondary genre (six of twenty records) and drops an edition's.
        MIN_SHARE = 0.25

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
          strong_support = Hash.new(0)
          subject_support = Hash.new(0)
          genre_bearing = 0
          subject_bearing = 0
          @records.each do |record|
            targets = record.genre.present? ? @map.targets_for(record.genre) : []
            if targets.any?
              genre_bearing += 1
              targets.each do |target|
                key = [target.kind, target.name]
                genre_support[key] += 1
                strong_support[key] += 1 unless target.weak
              end
            end
            phrases = ([record.genre] + record.subjects).compact.filter_map { |term| @map.subject_for(term) }.uniq
            subject_bearing += 1 if phrases.any?
            phrases.each { |phrase| subject_support[phrase] += 1 }
          end

          genres_linked = []
          audiences_linked = []
          weak_skipped = 0
          subjects_linked = []
          unresolved = []
          already = 0
          type_conflicts = 0

          supported(genre_support, genre_bearing).sort_by { |kind, name| [-genre_support[[kind, name]], kind.to_s, name] }.each do |kind, name|
            scope = (kind == :audience) ? ::Books::Category.active.audience : ::Books::Category.active.genre
            category = scope.by_name(name).first
            next unless category

            # WorldCat's "Juvenile" spans ages 0-15 and lands on children's editions
            # of classics: on its own it is not enough for a new audience link.
            if strong_support[[kind, name]].zero? && !@book.categories.active.exists?(id: category.id)
              weak_skipped += 1
              next
            end

            # A book is Fiction or Nonfiction, never both: WorldCat disagreeing with a
            # type the book already holds is a conflict to count, not to resolve.
            if type_conflict?(category)
              type_conflicts += 1
              next
            end

            created = link(category)
            if !created
              already += 1
            elsif kind == :audience
              audiences_linked << category.name
            else
              genres_linked << category.name
            end
          end
          supported(subject_support, subject_bearing).each do |phrase|
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
            records: @records.size, genres_linked: genres_linked.sort, audiences_linked: audiences_linked.sort, weak_skipped: weak_skipped, subjects_linked: subjects_linked.sort,
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

        # @param bearing [Integer] records carrying any mapped term of this kind
        def supported(support, bearing)
          threshold = (@records.size == 1) ? 1 : [MIN_SUPPORT, (bearing * MIN_SHARE).ceil].max
          support.select { |_key, n| n >= threshold }.keys
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
