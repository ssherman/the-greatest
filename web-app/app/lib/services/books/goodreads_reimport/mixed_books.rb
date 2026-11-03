# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReimport
      # Which book records are "mixed": one legacy record holding readers of
      # several different books (re-import spec). Only derived books can be:
      # a trusted book was put on a list by hand. The archive verdict records
      # everything on such a book before it is emptied and deleted, and is the
      # only way to reverse that deletion, so it is written once and kept.
      module MixedBooks
        module_function

        def ids
          ::Books::RebuildBookSurvey.lump
            .where(book_id: GoodreadsRebuild::Cohort.derived.select(:id))
            .pluck(:book_id).to_set
        end

        # RecordVerdict overwrites an unreviewed verdict's payload, so a re-run
        # carries the first snapshot forward itself: the "before" title and
        # authors, the archive, the row keys and the redirect. legacy_map is
        # built once per batch by the caller (building it scans every row).
        def archive(book, legacy_map: GoodreadsRebuild::LegacyBookMap.build)
          subject_key = "reimport:book:#{book.id}"
          kept = ::Books::RepairVerdict.find_by(kind: :reimport_mixed, subject_key: subject_key)&.payload || {}
          payload = {
            "book_id" => book.id,
            "title" => kept.fetch("title") { book.title },
            "subtitle" => kept.fetch("subtitle") { book.subtitle },
            "author_names" => kept.fetch("author_names") { book.book_authors.includes(:author).map { |ba| ba.author.name } },
            "archive" => kept["archive"] || snapshot(book),
            "row_keys" => kept["row_keys"] || row_keys(book, legacy_map)
          }
          payload["redirect_to_book_id"] = kept["redirect_to_book_id"] if kept.key?("redirect_to_book_id")
          # A kept verdict keeps its mark and its closing reason through a re-archive, or DecideGuesses could not reopen it.
          %w[kept closed_reason].each { |key| payload[key] = kept[key] if kept.key?(key) }
          GoodreadsReplay::RecordVerdict.call(kind: :reimport_mixed, subject_key: subject_key, payload: payload,
            decided_by: :rule, auto: true).data[:verdict]
        end

        # True while any reader is headed to the book: a current, unrejected, unsuperseded reimport_row whose
        # destination is it, or a current, unrejected reimport_match that matched an edition to it. Read from the
        # database, from anywhere, not from the book's own row_keys: a reader of another book can land here.
        def headed_to?(book_id)
          key = book_id.to_s
          rows = ::Books::RepairVerdict.reimport_row.current.where.not(status: :rejected)
            .where("payload->>'to_book_id' = ? AND COALESCE(payload->>'superseded_by', '') = ''", key)
          matches = ::Books::RepairVerdict.reimport_match.current.where.not(status: :rejected)
            .where("payload->>'outcome' = 'matched' AND payload->>'book_id' = ?", key)
          rows.exists? || matches.exists?
        end

        def snapshot(book)
          {
            "identifiers" => identifier_tuples(book.identifiers),
            "editions" => book.editions.includes(:identifiers).order(:id).map { |edition|
              {"id" => edition.id, "title" => edition.title, "subtitle" => edition.subtitle,
               "publication_year" => edition.publication_year, "publisher_name" => edition.publisher_name,
               "identifiers" => identifier_tuples(edition.identifiers.sort_by(&:id)),
               "external_links" => edition.external_links.order(:id).pluck(:url, :source),
               "images" => image_records(edition)}
            },
            "external_links" => book.external_links.order(:id).map { |link|
              {"id" => link.id, "name" => link.name, "url" => link.url, "source_name" => link.source_name}
            },
            "images" => image_records(book),
            "category_items" => book.category_items.order(:id).pluck(:category_id, :source),
            "list_items" => ::UserListItem.where(listable: book).joins(:user_list).order(:id)
              .pluck("user_list_items.user_list_id", "user_lists.user_id", "user_list_items.position",
                "user_list_items.completed_on", "user_list_items.created_at")
              .map { |list_id, user_id, position, completed_on, created_at|
                [list_id, user_id, position, completed_on.as_json, created_at.as_json]
              },
            "reviews" => ::Review.where(reviewable: book).order(:id).map { |review|
              [review.user_id, review.rating&.to_s, review.title, review.body, review.created_at.as_json]
            }
          }
        end

        # What it takes to put an image back: its own columns and the identity of the stored file. Deleting the
        # book destroys the Image rows; Apply::Mixed detaches each file first so the blob itself survives, and
        # this record names it (id, key, checksum) so a hand restore can attach it to a new Image.
        def image_records(parent)
          parent.images.includes(file_attachment: :blob).order(:id).map do |image|
            blob = image.file.blob
            {"id" => image.id, "primary" => image.primary, "notes" => image.notes, "metadata" => image.metadata,
             "parent_type" => image.parent_type, "parent_id" => image.parent_id, "created_at" => image.created_at.as_json,
             "blob" => blob && {"id" => blob.id, "key" => blob.key, "filename" => blob.filename.to_s,
                                "content_type" => blob.content_type, "checksum" => blob.checksum, "byte_size" => blob.byte_size}}
          end
        end

        def row_keys(book, legacy_map)
          legacy_ids = legacy_map.legacy_ids_for(book.id)
          ::Books::GoodreadsImportRow
            .joins(:import).where(books_goodreads_imports: {source: ::Books::GoodreadsImport.sources[:legacy_replay],
                                                            status: ::Books::GoodreadsImport.statuses[:complete]})
            .where(legacy_book_id: legacy_ids).where.not(goodreads_edition_id: nil)
            .order(:import_id, :row_number).pluck(:import_id, :row_number)
        end

        def identifier_tuples(identifiers)
          identifiers.sort_by(&:id).map { |identifier| [identifier.identifier_type, identifier.value, identifier.source] }
        end
      end
    end
  end
end
