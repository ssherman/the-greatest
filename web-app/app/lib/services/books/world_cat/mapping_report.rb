# frozen_string_literal: true

module Services
  module Books
    module WorldCat
      # Two reports for the owner: the top terms with their verdicts (a sanity check)
      # and the terms the pass could not place on a genre, ranked by how many of our
      # books carry them (the list for deciding whether a new genre is warranted).
      class MappingReport
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        UNPLACED_DROP_REASONS = %w[not_a_genre too_specific].freeze

        def self.call(map:, out_path:, top: 300)
          new(map:, out_path:, top:).call
        end

        def initialize(map:, out_path:, top:)
          @map = map
          @out_path = Pathname(out_path)
          @top = top
        end

        def call
          rows = []
          @map.each_term { |term, entry| rows << row(term, entry) }
          rows.sort_by! { |r| [-r[:uses], r[:term]] }
          top = rows.first(@top)
          unplaced = rows.select { |r| r[:verdict] == "subject" || (r[:verdict] == "drop" && UNPLACED_DROP_REASONS.include?(r[:reason])) }
            .sort_by { |r| [-r[:books], r[:term]] }
          counts = %w[genre subject drop].to_h { |v| [v.to_sym, rows.count { |r| r[:verdict] == v }] }
          @out_path.dirname.mkpath
          @out_path.write(render(top, unplaced, counts))
          Result.new(success?: true, data: {top:, unplaced:, counts:}, errors: [])
        end

        private

        def row(term, entry)
          {term:, verdict: entry["verdict"], genre: entry["genre"], subject: entry["subject"], reason: entry["reason"],
           language: entry["language"], uses: entry["uses"].to_i, books: entry["books"].to_i}
        end

        def target(r)
          r[:genre] || r[:subject] || r[:reason]
        end

        def render(top, unplaced, counts)
          lines = ["# WorldCat genre mapping", "",
            "**Generated #{Date.current}** by `bin/rails worldcat:report` from `config/worldcat/genre_map.yml`",
            "(#{@map.size} terms: #{counts[:genre]} genre, #{counts[:subject]} subject, #{counts[:drop]} drop).",
            "Regenerate after editing the map; this page describes one file on one day.", "",
            "## Top #{top.size} terms by uses", "", "| Term | Uses | Books | Verdict | Target |", "|---|---:|---:|---|---|"]
          top.each { |r| lines << "| #{r[:term]} | #{r[:uses]} | #{r[:books]} | #{r[:verdict]} | #{target(r)} |" }
          lines += ["", "## Terms with no genre", "",
            "Subject verdicts and drops for `not_a_genre`/`too_specific`, ranked by how many of our books carry them.",
            "Each is a candidate for a new genre, a merge onto an existing one, or staying as it is.", "",
            "| Term | Books | Uses | Verdict | Target | Language |", "|---|---:|---:|---|---|---|"]
          unplaced.each { |r| lines << "| #{r[:term]} | #{r[:books]} | #{r[:uses]} | #{r[:verdict]} | #{target(r)} | #{r[:language]} |" }
          lines.join("\n") + "\n"
        end
      end
    end
  end
end
