# frozen_string_literal: true

module Services
  module Books
    module GoodreadsRebuild
      # Survey pass 2 for one edition (rebuild spec §4.2): what WorldCat and
      # Open Library say about its ISBN. WorldCat agrees when a record's title
      # and creator both match the export; disagrees when neither does; is
      # unclear otherwise. Open Library gives the work keys the ISBN belongs
      # to. Both lookups happen before the write, so a service error stores
      # nothing for the edition. Upserts by natural key.
      module GatherEvidence
        module_function

        def call(edition:, world_cat:, open_library:)
          isbn13 = isbn13_for(edition)
          records = isbn13 ? world_cat.record_by_isbn(isbn13) : []
          hits = isbn13 ? open_library.identifier("isbn_13", isbn13) : []
          verdicts = records.map { |record| [record, verdict(edition, record)] }
          shown = verdicts.find { |_, said| said == :agrees }&.first || records.first

          evidence = ::Books::RebuildEditionEvidence.find_or_initialize_by(goodreads_book_id: edition.goodreads_book_id,
            signature: edition.signature)
          evidence.update!(isbn13: isbn13, world_cat: overall(isbn13, verdicts), ol_work_keys: hits.filter_map(&:work_key).uniq,
            world_cat_title: shown&.title, world_cat_creator: shown&.creator, world_cat_year: shown&.year, checked_at: Time.current)
          evidence
        rescue ActiveRecord::RecordNotUnique
          # Another thread wrote this edition between the lookup and the insert.
          retry
        end

        def isbn13_for(edition)
          [edition.isbn13, edition.isbn10].each do |raw|
            normalized = ::Books::Isbn.normalize(raw) if raw.present?
            return normalized.isbn13 if normalized
          end
          nil
        end

        def verdict(edition, record)
          book = EditionLike.from(edition)
          work = ::Services::Books::Verification::WorldCatCheck.work_like(record)
          title = check.titles_agree?(book, work)
          authors = check.authors_agree?(book, work)
          return :agrees if title && authors
          return :disagrees if !title && !authors

          :unclear
        end

        def overall(isbn13, verdicts)
          return :no_isbn unless isbn13
          return :no_record if verdicts.empty?

          said = verdicts.map(&:last)
          [:agrees, :disagrees].find { |verdict| said.include?(verdict) } || :unclear
        end

        def check = ::Services::Books::Verification::Check
      end
    end
  end
end
