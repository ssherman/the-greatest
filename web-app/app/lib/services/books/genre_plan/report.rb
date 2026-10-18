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
          lines.concat(slug_block)
          Result.new(success?: true, data: {lines: lines}, errors: [])
        end

        private

        # Decisions that leave the category dead (deleted, merged away), so its slug frees up.
        def ends_dead?(decision)
          return false unless decision.is_a?(Hash)

          case decision["action"]
          when "delete", "merge", "location" then true
          when "subject" then decision["target_id"].present?
          when "split" then !renaming_split?(decision)
          else false
          end
        end

        def renaming_split?(decision)
          primary = Array(decision["into"]).first
          return false unless primary.is_a?(String) && @plan.genre_names.include?(primary)

          @plan.decisions.values.none? do |d|
            (d["action"] == "keep" && d["name"] == primary) || (d["action"] == "rename" && d["to"] == primary) || (d["action"] == "audience" && d["as"] == primary)
          end
        end

        # [category id, the name it ends with] for every rename, renaming split and audience rename.
        def renamed_names
          @plan.decisions.sort.filter_map do |id, d|
            name = case d["action"]
            when "rename" then d["to"]
            when "audience" then d["as"] if d["as"].present? && d["as"] != d["name"]
            when "split" then Array(d["into"]).first if renaming_split?(d)
            end
            [id, name] if name.is_a?(String) && name.present?
          end
        end

        # A rename takes the clean slug of its new name only when dead categories
        # hold it (the applier reclaims it then). A live category the plan keeps
        # holds it for good, so the renamed category gets a UUID-suffixed slug.
        def slug_block
          lines = []
          renamed_names.each do |id, name|
            clean = name.parameterize
            next if clean.blank?

            history = FriendlyId::Slug.where(sluggable_type: "Category", scope: ::Books::CategorySlugResolver::HISTORY_SCOPE, slug: clean).pluck(:sluggable_id)
            holders = ::Books::Category.active.where(slug: clean).or(::Books::Category.active.where(id: history)).where.not(id: id).order(:id)
            holders.reject { |holder| ends_dead?(@plan.decisions[holder.id]) }.each do |holder|
              lines << "#{id} #{@plan.decisions[id]["name"]} -> #{name}: slug #{clean.inspect} is held by live #{holder.id} #{holder.name} (#{holder.category_type})"
            end
          end
          lines.any? ? ["", "== slug conflicts (#{lines.size})", *lines] : []
        end

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
