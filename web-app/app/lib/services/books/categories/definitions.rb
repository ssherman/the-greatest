# frozen_string_literal: true

module Services
  module Books
    module Categories
      # Copies the reviewed genre/audience definitions from config/books/genre_plan.yml
      # into categories.description, where the categories task reads them. The plan is
      # authoritative (owner decision, 2026-11-10: the old descriptions are unused old-site
      # blurbs): any held description that differs is overwritten, and a non-blank one that
      # was replaced is reported in replaced.
      class Definitions
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        PLAN_KEYS = {"genres" => :genre, "audiences" => :audience}.freeze

        def self.call(apply:, plan_path: Rails.root.join("config/books/genre_plan.yml"))
          new(apply: apply, plan_path: plan_path).call
        end

        def initialize(apply:, plan_path:)
          @apply = apply
          @plan_path = plan_path
        end

        def call
          plan = YAML.safe_load_file(@plan_path.to_s) || {}
          written = []
          replaced = []
          missing = []

          PLAN_KEYS.each do |key, type|
            entries = Array(plan[key]).to_h { |entry| [entry["name"].to_s.downcase, entry["definition"].to_s.strip] }
            ::Books::Category.active.where(category_type: type).order(:name).each do |category|
              wanted = entries[category.name.downcase]
              if wanted.blank?
                missing << category.name if category.description.blank?
              elsif category.description != wanted
                replaced << {name: category.name, held: category.description, plan: wanted} if category.description.present?
                category.update_columns(description: wanted) if @apply
                written << category.name
              end
            end
          end

          Result.new(success?: true, data: {written: written, replaced: replaced, missing: missing}, errors: [])
        end
      end
    end
  end
end
