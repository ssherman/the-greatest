# frozen_string_literal: true

module Services
  module Books
    module GenrePlan
      # `categories:genres:report` (spec §5 step 5): what the owner reviews.
      class Report
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        SAMPLES = 20

        def self.call(plan:, assignments:)
          new(plan, assignments).call
        end

        def initialize(plan, assignments)
          @plan = plan
          @assignments = assignments
        end

        def call
          lines = []
          @plan.decisions.sort.group_by { |_, d| d["action"] }.sort.each do |action, rows|
            lines << "" << "== #{action} (#{rows.size})"
            rows.each do |id, d|
              refs = (action == "delete" || d["saved_searches"].to_i.positive?) ? ", saved searches + recommendation settings #{d["saved_searches"].to_i}" : ""
              lines << ["#{id} #{d["name"]}#{target(d)} (books #{d["books"].to_i}#{refs})", d["reason"]].compact_blank.join(" ")
            end
          end
          @plan.decisions.sort.each { |id, d| lines.concat(split_block(id, d)) if d["action"] == "split" }
          Result.new(success?: true, data: {lines: lines}, errors: [])
        end

        private

        def target(d)
          to = d["to"] || d["as"] || ((d["action"] == "split") ? Array(d["into"]).map { |e| Validator.target_label(e) }.join(" + ") : d["into"])
          to = "delete" if to.nil? && d["worldcat"]
          extra = Array(d["also"]).any? ? " also #{d["also"].join(", ")}" : ""
          extra += " (worldcat #{d["worldcat"]})" if d["worldcat"]
          extra += " (target #{d["target_id"]})" if d["target_id"]
          to ? " -> #{to}#{extra}" : extra
        end

        def split_block(id, d)
          answers = @assignments.for(id)
          on_genre = ::CategoryItem.where(category_id: id, item_type: "Books::Book").order(:item_id).pluck(:item_id)
          outcomes = Hash.new { |h, k| h[k] = [] }
          on_genre.each { |book_id| outcomes[outcome(answers[book_id])] << book_id }
          titles = ::Books::Book.where(id: outcomes.values.flat_map { |ids| ids.first(SAMPLES) }).pluck(:id, :title).to_h
          lines = ["", "== split #{d["name"]} (#{on_genre.size} books)"]
          outcomes.sort.each do |key, ids|
            lines << "#{key}: #{ids.size}"
            lines << "  #{ids.first(SAMPLES).map { |book_id| titles[book_id] }.join(" | ")}"
          end
          Array(d["into"]).map { |entry| Validator.target_label(entry) }.each do |label|
            count = on_genre.count { |book_id| answers[book_id].is_a?(Array) && answers[book_id].include?(label) }
            lines << "#{label} (any): #{count}"
          end
          lines
        end

        def outcome(answer)
          if answer.nil? then "unanswered"
          elsif answer == :unknown then "unknown"
          elsif answer.empty? then "none"
          elsif answer.size > 1 then "several"
          else answer.first
          end
        end
      end
    end
  end
end
