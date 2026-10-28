# frozen_string_literal: true

module Services
  module Books
    module GoodreadsRebuild
      # Which legacy book ids name a book now. An export row keeps legacy's
      # choice in legacy_book_id; when that book has since been merged away,
      # its rows belong to the book it was merged into (MergedBook follows the
      # merge). Built once per survey run: the vanished ids are a few thousand.
      class LegacyBookMap
        def self.build
          vanished = ::Books::GoodreadsImportRow.where.not(legacy_book_id: nil)
            .where.not(legacy_book_id: ::Books::Book.select(:id)).distinct.pluck(:legacy_book_id)
          merged_into = Hash.new { |hash, key| hash[key] = [] }
          vanished.each do |legacy_id|
            survivor = ::Services::Books::GoodreadsReplay::Apply::MergedBook.call(legacy_id)
            merged_into[survivor.id] << legacy_id if survivor
          end
          new(merged_into)
        end

        def initialize(merged_into)
          @merged_into = merged_into
        end

        def legacy_ids_for(book_id) = ([book_id] + @merged_into.fetch(book_id, [])).sort

        def all_legacy_ids_for(book_ids) = book_ids.flat_map { |id| legacy_ids_for(id) }.uniq
      end
    end
  end
end
