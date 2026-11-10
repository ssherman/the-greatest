# frozen_string_literal: true

module Services
  module Books
    module Categories
      # Copies the reviewed genre/audience definitions from config/books/genre_plan.yml
      # into categories.description, where the categories task reads them. Fills
      # blanks only: a description someone already wrote is kept and reported.
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
          kept = []
          missing = []

          PLAN_KEYS.each do |key, type|
            entries = Array(plan[key]).to_h { |entry| [entry["name"].to_s.downcase, entry["definition"].to_s.strip] }
            ::Books::Category.active.where(category_type: type).order(:name).each do |category|
              wanted = entries[category.name.downcase]
              if wanted.blank?
                missing << category.name if category.description.blank?
              elsif category.description.blank?
                category.update_columns(description: wanted) if @apply
                written << category.name
              elsif category.description != wanted
                kept << {name: category.name, held: category.description, plan: wanted}
              end
            end
          end

          Result.new(success?: true, data: {written: written, kept: kept, missing: missing}, errors: [])
        end
      end
    end
  end
end
