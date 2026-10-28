# frozen_string_literal: true

module Services
  module Books
    module GoodreadsRebuild
      # Moves survey pass 2's evidence from Shane's PC to production (rebuild
      # spec §4.2) as gzipped JSON lines, one row per line, keyed by the
      # edition's natural key. Import upserts, so it can be re-run, and keeps
      # rows for editions this database does not hold yet: a later weekly
      # load may bring them.
      module EvidenceTransfer
        module_function

        COLUMNS = %w[goodreads_book_id signature isbn13 world_cat world_cat_title world_cat_creator world_cat_year
          ol_work_keys checked_at].freeze
        SLICE = 1_000

        def export(path)
          count = 0
          Zlib::GzipWriter.open(path) do |gz|
            ::Books::RebuildEditionEvidence.in_batches(of: SLICE) do |batch|
              batch.pluck(*COLUMNS).each do |values|
                gz.puts(COLUMNS.zip(values).to_h.merge("world_cat" => values[3], "checked_at" => values[8].iso8601(6)).to_json)
                count += 1
              end
            end
          end
          count
        end

        def import(path)
          counts = {"imported" => 0, "no_edition_here" => 0}
          Zlib::GzipReader.open(path) do |gz|
            gz.each_line.each_slice(SLICE) do |lines|
              rows = lines.map { |line| row(JSON.parse(line)) }
              ::Books::RebuildEditionEvidence.upsert_all(rows, unique_by: [:goodreads_book_id, :signature])
              counts["imported"] += rows.size
              counts["no_edition_here"] += rows.size - present(rows)
            end
          end
          counts
        end

        def row(hash)
          now = Time.current
          hash.slice(*COLUMNS).merge("world_cat" => ::Books::RebuildEditionEvidence.world_cats.fetch(hash["world_cat"]),
            "checked_at" => Time.iso8601(hash["checked_at"]), "created_at" => now, "updated_at" => now)
        end

        def present(rows)
          keys = rows.map { |row| [row["goodreads_book_id"], row["signature"]] }.to_set
          ::Books::GoodreadsEdition.where(goodreads_book_id: rows.map { |row| row["goodreads_book_id"] }.uniq)
            .pluck(:goodreads_book_id, :signature).count { |key| keys.include?(key) }
        end
      end
    end
  end
end
