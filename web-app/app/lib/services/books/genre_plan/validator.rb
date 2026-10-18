# frozen_string_literal: true

module Services
  module Books
    module GenrePlan
      # The pre-apply checks of spec §4. Any error stops the apply.
      class Validator
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        ACTIONS = %w[keep rename merge audience subject location delete split].freeze
        BOOK_TYPE_NAMES = ::Books::Book::BOOK_TYPE_CATEGORY_NAMES

        def self.call(plan:, assignments:)
          new(plan, assignments).call
        end

        def self.target_label(entry) = entry.is_a?(Hash) ? entry["subject"].to_s : entry.to_s

        def initialize(plan, assignments)
          @plan = plan
          @assignments = assignments
        end

        def call
          errors = []
          live = ::Books::Category.active.genre.pluck(:id, :name).to_h
          all_decisions = @plan.decisions
          decisions = all_decisions.select { |_id, d| d.is_a?(Hash) }
          (all_decisions.keys - decisions.keys).each { |id| errors << "#{id}: the decision must be a mapping with a name and an action" }

          errors.concat(check_list_names)
          missing = live.keys - decisions.keys
          errors << "live genres missing from the plan: #{missing.map { |id| "#{id} #{live[id]}" }.join(", ")}" if missing.any?
          if @plan.audience_names != PlanFile::AUDIENCES.keys
            errors << "audiences must be exactly #{PlanFile::AUDIENCES.keys.join(", ")}"
          end

          decisions.each do |id, decision|
            label = "#{id} #{decision["name"].inspect}"
            unless live.key?(id)
              errors << "#{label}: not a live genre"
              next
            end
            errors << "#{label}: the live name is #{live[id].inspect}" if live[id] != decision["name"]
            errors.concat(check(decision, label))
          end
          errors.concat(check_protected(decisions))
          errors.concat(check_producers(decisions))
          errors.concat(check_assignments(decisions))
          Result.new(success?: errors.empty?, data: nil, errors: errors)
        end

        private

        def check_list_names
          names = list_names.map { |n| n.to_s.downcase }
          dupes = names.select { |n| names.count(n) > 1 }.uniq
          dupes.any? ? ["duplicate names across the genre and audience lists: #{dupes.join(", ")}"] : []
        end

        def list_names = @list_names ||= @plan.genre_names + @plan.audience_names

        def check(decision, label)
          errors = []
          action = decision["action"]
          return ["#{label}: unknown action #{action.inspect}"] unless ACTIONS.include?(action)

          case action
          when "keep"
            errors << "#{label}: keep, but #{decision["name"].inspect} is not on the genre list" unless @plan.genre_names.include?(decision["name"])
          when "rename"
            errors << "#{label}: rename to #{decision["to"].inspect}, which is not on the genre list" unless @plan.genre_names.include?(decision["to"])
          when "merge"
            errors.concat(check_target(decision["into"], label))
          when "audience"
            errors << "#{label}: #{decision["as"].inspect} is not an audience" unless @plan.audience_names.include?(decision["as"])
          when "subject"
            errors.concat(check_live(decision["target_id"], :subject, decision["as"], label)) if decision["target_id"]
          when "location"
            if decision["target_id"]
              errors.concat(check_live(decision["target_id"], :location, decision["as"], label))
            else
              errors << "#{label}: a location needs a target_id"
            end
          when "split"
            errors.concat(check_split(decision, label))
          end

          also = Array(decision["also"])
          if also.any?
            own = (action == "rename") ? decision["to"] : decision["name"]
            if !%w[keep rename].include?(action)
              errors << "#{label}: also is only for keep and rename"
            elsif also.any? { |name| !@plan.genre_names.include?(name) || name == own || BOOK_TYPE_NAMES.include?(name) }
              errors << "#{label}: also must name other genres on the list, never Fiction or Nonfiction"
            end
          end
          if decision["worldcat"] && !list_names.include?(decision["worldcat"])
            errors << "#{label}: worldcat #{decision["worldcat"].inspect} is not on a list"
          end
          errors
        end

        def check_target(name, label)
          return ["#{label}: #{name.inspect} is not on a list"] unless list_names.include?(name)
          return ["#{label}: nothing merges into #{name}"] if BOOK_TYPE_NAMES.include?(name)

          []
        end

        def check_live(id, type, name, label)
          category = ::Books::Category.active.where(category_type: type).find_by(id: id)
          return ["#{label}: target_id #{id} is not a live #{type}"] if category.nil?
          return ["#{label}: target_id #{id} is #{category.name.inspect}, not #{name.inspect}"] if name.present? && !category.name.casecmp?(name)

          []
        end

        def check_split(decision, label)
          into = Array(decision["into"])
          labels = into.map { |entry| self.class.target_label(entry) }
          errors = []
          errors << "#{label}: a split needs at least two targets" if into.size < 2
          errors << "#{label}: a split names a target twice" if labels.uniq.size != labels.size
          into.each do |entry|
            if entry.is_a?(Hash)
              errors.concat(check_live(entry["target_id"], :subject, entry["subject"], label))
            else
              errors.concat(check_target(entry, label))
            end
          end
          list_targets = into.grep(String)
          (decision["worldcat_terms"] || {}).each do |term, names|
            # An empty list is valid: the term supports none of the halves and becomes a drop at retarget.
            bad = Array(names) - list_targets
            errors << "#{label}: worldcat_terms #{term.inspect} names #{bad.join(", ")}, not this split's genres" if bad.any?
          end
          errors
        end

        def check_protected(decisions)
          ::Books::Category.protected_ids.filter_map do |id|
            decision = decisions[id]
            next if decision.nil?

            "#{decision["name"]} is protected: it must be a plain keep" unless decision["action"] == "keep" && Array(decision["also"]).empty?
          end
        end

        # The first split (by category id) whose primary nothing else produces
        # renames to it; later splits with the same primary merge into it.
        # DecisionBuilder makes the same choice in the same order.
        def check_producers(decisions)
          producers = Hash.new(0)
          decisions.sort.each do |_id, d|
            case d["action"]
            when "keep" then producers[d["name"]] += 1
            when "rename" then producers[d["to"]] += 1
            when "audience" then producers[d["as"]] += 1
            end
          end
          ::Books::Category.active.audience.where(name: @plan.audience_names).pluck(:name).each { |name| producers[name] += 1 }
          # A split renames its genre to its primary only when the primary is a
          # genre-list name. An audience-name primary needs an audience producer.
          decisions.sort.each do |_id, d|
            next unless d["action"] == "split"

            primary = Array(d["into"]).first
            producers[primary] += 1 if primary.is_a?(String) && @plan.genre_names.include?(primary) && producers[primary].zero?
          end

          list_names.filter_map do |name|
            count = producers[name]
            next if count == 1

            count.zero? ? "#{name} is produced by no decision" : "#{name} is produced by #{count} decisions"
          end
        end

        def check_assignments(decisions)
          errors = []
          @assignments.each do |book_id, category_id, targets|
            decision = decisions[category_id]
            if decision.nil? || decision["action"] != "split"
              errors << "split answers for #{category_id}, which is not a split"
              next
            end
            next if targets == :unknown

            allowed = Array(decision["into"]).map { |entry| self.class.target_label(entry) }
            bad = targets - allowed
            errors << "book #{book_id} on #{decision["name"]}: #{bad.join(", ")} is not one of its targets" if bad.any?
          end
          errors.uniq
        end
      end
    end
  end
end
