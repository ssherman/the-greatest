module Actions
  module Admin
    module Books
      # Every Books:: constant in here is root-anchored. Inside
      # Actions::Admin::Books, a bare `Books::Author` resolves to
      # Actions::Admin::Books::Author and raises a confusing NameError.
      class MergeAuthor < Actions::Admin::BaseAction
        def self.name
          "Merge Another Author Into This One"
        end

        def self.message
          "Search for a duplicate author to merge into the current author. The source author will be permanently deleted after merging."
        end

        def self.confirm_button_label
          "Merge Author"
        end

        def self.visible?(context = {})
          context[:view] == :show
        end

        def self.destructive?
          true
        end

        def call
          return error("This action can only be performed on a single author.") if models.count != 1

          target_author = models.first

          source_author_id = fields[:source_author_id] || fields["source_author_id"]
          confirm_merge = fields[:confirm_merge] || fields["confirm_merge"]

          unless source_author_id.present?
            return error("Please select an author to merge.")
          end

          unless confirm_merge == "1" || confirm_merge == true
            return error("Please confirm you understand this action cannot be undone.")
          end

          source_author = ::Books::Author.find_by(id: source_author_id)

          unless source_author
            return error("Author with ID #{source_author_id} not found.")
          end

          if source_author.id == target_author.id
            return error("Cannot merge an author with itself. Please select a different author.")
          end

          source_name = source_author.name
          source_id = source_author.id

          merger = ::Books::Author::Merger.new(source: source_author, target: target_author)
          result = merger.call

          if result.success?
            message = "Successfully merged '#{source_name}' (ID: #{source_id}) into '#{target_author.name}'. The source author has been deleted."

            if merger.stats[:post_commit_error].present?
              warn "#{message} Note: search reindexing and ranking recalculation could not be " \
                "scheduled (#{merger.stats[:post_commit_error]}); they will need to be re-run."
            else
              succeed message
            end
          else
            error "Failed to merge authors: #{result.errors.join(", ")}"
          end
        end
      end
    end
  end
end
