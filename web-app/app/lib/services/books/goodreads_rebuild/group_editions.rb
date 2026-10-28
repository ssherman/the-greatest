# frozen_string_literal: true

module Services
  module Books
    module GoodreadsRebuild
      # Sorts the Goodreads editions a book's export rows name into works
      # (rebuild spec §4). Editions are one work when they share an author
      # (letters only, so "J.D." and "J. D." agree), an original publication
      # year and a series volume. Translations agree on author and year
      # however their titles differ. An Open Library work shared by two
      # editions of the same volume joins their groups, because Goodreads may
      # spell a translated author differently ("Lev" for "Leo" Tolstoy);
      # pass 1 has no Open Library evidence and skips that step. An edition
      # missing its author, year or volume joins the biggest group it doesn't
      # contradict. Two or more groups make the book a lump.
      class GroupEditions
        Info = Struct.new(:edition, :author_key, :year, :volume, :rows, keyword_init: true)

        def self.call(editions:, row_counts:, evidence: {})
          new(editions, row_counts, evidence).call
        end

        def self.classify(groups)
          case groups.size
          when 0 then :unsupported
          when 1 then :coherent
          else :lump
          end
        end

        def initialize(editions, row_counts, evidence)
          @infos = editions.map do |edition|
            Info.new(edition: edition, author_key: ::Services::Books::Verification::Check.compact(edition.primary_author),
              year: edition.original_publication_year, volume: edition.series_number.to_s.strip.presence,
              rows: row_counts.fetch(edition.id, 0))
          end
          @evidence = evidence
        end

        # Editions with author, year and volume all set group exactly. The rest
        # (most books have no volume) join the biggest group they don't
        # contradict, so "Hunter x Hunter, Vol. 13" and its unnumbered
        # printing are one work. Open Library merges run last, over every group.
        def call
          complete, partial = @infos.partition { |info| info.author_key && info.year && info.volume }
          groups = complete.group_by { |info| [info.author_key, info.year, info.volume] }.values
          partial.sort_by { |info| [-info.rows, info.edition.goodreads_book_id.to_i] }.each { |info| place(info, groups) }
          merge_by_open_library_work(groups).map { |members| to_hash(members) }
            .sort_by { |group| [-group["row_count"], group["goodreads_book_ids"].first.to_i] }
        end

        private

        # Union-find over group indexes: two groups join when an edition in
        # each names the same Open Library work and their volumes don't
        # contradict (equal, or one missing).
        def merge_by_open_library_work(groups)
          parent = (0...groups.size).to_a
          find = ->(i) { (parent[i] == i) ? i : (parent[i] = find.call(parent[i])) }
          seen = Hash.new { |hash, key| hash[key] = [] }
          groups.each_with_index do |members, index|
            members.each do |info|
              work_keys(info).each do |key|
                seen[key].each do |other_index, volume|
                  parent[find.call(index)] = find.call(other_index) if compatible?(volume, info.volume)
                end
                seen[key] << [index, info.volume]
              end
            end
          end
          groups.each_with_index.group_by { |_, index| find.call(index) }.values.map { |pairs| pairs.flat_map(&:first) }
        end

        def compatible?(ours, theirs) = ours.nil? || theirs.nil? || ours == theirs

        def work_keys(info) = Array(@evidence[info.edition.id]&.ol_work_keys)

        def place(info, groups)
          matches = groups.select { |members| fits?(info, members) }
          target = matches.max_by { |members| [members.sum(&:rows), -members.map { |m| m.edition.goodreads_book_id.to_i }.min] }
          target ? target << info : groups << [info]
        end

        # Every field the edition has must match a member's, where the member
        # has it too; a missing one contradicts nothing.
        def fits?(info, members)
          members.any? do |member|
            compatible?(member.volume, info.volume) && compatible?(member.author_key, info.author_key) &&
              compatible?(member.year, info.year)
          end
        end

        def to_hash(members)
          by_rows = members.sort_by { |info| [-info.rows, info.edition.goodreads_book_id.to_i] }
          {
            "edition_ids" => members.map { |info| info.edition.id }.sort,
            "goodreads_book_ids" => members.map { |info| info.edition.goodreads_book_id }.sort,
            "titles" => by_rows.map { |info| info.edition.title }.uniq.first(3),
            "authors" => by_rows.map { |info| info.edition.primary_author }.compact.uniq.first(3),
            "year" => members.filter_map(&:year).tally.max_by { |year, count| [count, -year] }&.first,
            "volume" => by_rows.first.volume,
            "row_count" => members.sum(&:rows)
          }
        end
      end
    end
  end
end
