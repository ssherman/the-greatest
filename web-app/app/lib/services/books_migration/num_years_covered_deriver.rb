module Services
  module BooksMigration
    # First pass at Books::List#num_years_covered for the review file: how many
    # publication years the list's scope allowed. Pure -- takes rows and returns
    # Entry structs; the rake task does the legacy reads and the file write.
    # The name is parsed first and the description only when the name yields
    # nothing (description matches are the false positives, so they are flagged).
    # The one-year bucket is never parsed: legacy meant "each pick is best of one
    # year", however many years a yearly award spans. Every entry says why, so the
    # reviewer can find the wrong ones fast.
    class NumYearsCoveredDeriver
      Entry = Struct.new(:id, :years, :name, :bucket, :reason, :flags, keyword_init: true) do
        def to_line
          note = flags.any? ? "; #{flags.join("; ")}" : ""
          "#{id}: #{years}   # #{name}  (#{bucket} -> #{reason}#{note})"
        end
      end

      YEAR = "(1[5-9]\\d\\d|20[0-2]\\d)"
      RANGE = /\b#{YEAR}\s*(?:-|to|through|until)\s*#{YEAR}\b/i
      PAST_N = /\b(?:past|last|previous)\s+(\d{1,3})\s+years\b/i
      HALF_CENTURY = /\bhalf[- ]century\b/i
      QUARTER_CENTURY = /\bquarter[- ]century\b/i
      SINCE = /\b(?:since|from)\s+#{YEAR}\b/i
      DECADE = /\b(?:19|20)\d0s\b|\b[2-9]0s\b|\bdecade\b/i
      TWENTY_FIRST = /\b21st[- ]century\b|\bXXI\b/i
      CENTURY = /\b(?:20th|twentieth)[- ]century\b|\bcentury\b|\b100 years\b|\bwieku\b/i
      MILLENNIUM = /\bmillenni/i

      def self.call(rows, current_year: Date.current.year)
        rows.map { |row| new(row, current_year).entry }
      end

      # The rows `call` wants, read from the legacy database: every list carrying a
      # year-span static on an ACTIVE legacy configuration (the same set the
      # migration maps), with its bucket from the highest configuration id and every
      # bucket it carries for the CONFLICT flag. Legacy-only on purpose: the file can
      # be regenerated before, after, or without a migration run.
      def self.legacy_rows
        buckets = PenaltyResolver::YEAR_SPAN_BUCKETS
        active_ids = LegacyBooks::RankingConfiguration.where(archived: false).pluck(:id)
        cons = LegacyBooks::ListCon
          .where(name: buckets.keys, ranking_configuration_id: active_ids)
          .pluck(:id, :name, :ranking_configuration_id)
          .to_h { |id, name, rc_id| [id, [rc_id, buckets.fetch(name)]] }
        pairs = LegacyBooks::ListConList
          .where(list_con_id: cons.keys)
          .joins("JOIN ranked_lists ON ranked_lists.id = list_con_lists.ranked_list_id")
          .pluck(Arel.sql("ranked_lists.list_id"), :list_con_id)
        by_list = pairs.group_by(&:first).transform_values { |ps| ps.map { |_, con_id| cons.fetch(con_id) } }

        LegacyBooks::List.where(id: by_list.keys).order(:id).map do |list|
          hits = by_list.fetch(list.id)
          {
            id: list.id,
            name: list.name,
            description: list.description,
            year_published: list.year_published,
            bucket: hits.max_by(&:first).last,
            buckets: hits.map(&:last).uniq
          }
        end
      end

      def initialize(row, current_year)
        @row = row
        @current_year = current_year
        @flags = []
      end

      def entry
        buckets = @row[:buckets].uniq
        @flags << "CONFLICT #{buckets.sort.join("/")}, highest RC wins" if buckets.size > 1
        return build(1, "one-year bucket, never parsed") if @row[:bucket] == 1

        years, reason = parse(@row[:name])
        if years.nil? && reason.nil? && @row[:description].present?
          years, reason = parse(@row[:description])
          @flags.unshift("FROM DESCRIPTION") if reason
        end

        return build(@row[:bucket], reason || "unparsed") if years.nil?

        build(years, reason)
      end

      private

      def build(years, reason)
        Entry.new(id: @row[:id], years: years, name: @row[:name], bucket: @row[:bucket], reason: reason, flags: @flags)
      end

      # => [years, reason] on a match, [nil, reason] on a match that yields no
      # number (millennium), nil when nothing matched.
      def parse(text)
        text = text.to_s.tr("–—", "--")

        if (m = text.match(RANGE))
          from, to = m[1].to_i, m[2].to_i
          return [to - from + 1, "range #{from}-#{to}"] if to >= from && to - from < 400
        end
        if (m = text.match(PAST_N))
          return [m[1].to_i, "past #{m[1]} years"]
        end
        return [50, "half century"] if text.match?(HALF_CENTURY)
        return [25, "quarter century"] if text.match?(QUARTER_CENTURY)
        if (m = text.match(SINCE))
          from = m[1].to_i
          published, substituted = publication_year
          if published > from
            flag_no_year_published if substituted
            return [published - from + 1, "since #{from}, published #{published}"]
          end
        end
        return [10, "decade"] if text.match?(DECADE)
        if text.match?(TWENTY_FIRST)
          published, substituted = publication_year
          if published > 2000
            flag_no_year_published if substituted
            return [published - 2000, "21st century so far, published #{published}"]
          end
        end
        return [100, "century"] if text.match?(CENTURY)
        return [nil, "millennium: left to the reviewer"] if text.match?(MILLENNIUM)

        nil
      end

      # => [year, substituted?]. Does not flag by itself -- the caller only
      # knows whether the substituted year was actually used once its own
      # guard (published > from / published > 2000) passes, so flagging
      # happens there, not here.
      def publication_year
        return [@row[:year_published], false] if @row[:year_published]

        [@current_year, true]
      end

      def flag_no_year_published
        flag = "NO year_published (used #{@current_year})"
        @flags << flag unless @flags.include?(flag)
      end
    end
  end
end
