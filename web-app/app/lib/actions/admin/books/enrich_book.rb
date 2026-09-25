module Actions
  module Admin
    module Books
      # Every Books:: constant in here is root-anchored. Inside
      # Actions::Admin::Books, a bare `Books::Book` resolves to
      # Actions::Admin::Books::Book and raises a confusing NameError.
      class EnrichBook < Actions::Admin::BaseAction
        def self.name
          "Enrich With AI"
        end

        def self.message
          "Look up missing metadata and a description for this book in the background. Existing values are never overwritten."
        end

        def self.confirm_button_label
          "Enrich Book"
        end

        def self.visible?(context = {})
          context[:view] == :show
        end

        def call
          return error("This action can only be performed on a single book.") if models.count != 1

          book = models.first
          force = ActiveModel::Type::Boolean.new.cast(fields[:force_research] || fields["force_research"]) || false

          ::Books::EnrichBookJob.perform_async(book.id, force)

          succeed(force ? "Enrichment with web search queued for #{book.title}." : "Enrichment queued for #{book.title}.")
        end
      end
    end
  end
end
