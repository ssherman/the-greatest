module Actions
  module Admin
    module Games
      class MergeGame < Actions::Admin::BaseAction
        def self.name
          "Merge Another Game Into This One"
        end

        def self.message
          "Search for a duplicate game to merge into the current game. The source game will be permanently deleted after merging."
        end

        def self.confirm_button_label
          "Merge Game"
        end

        def self.visible?(context = {})
          context[:view] == :show
        end

        def self.destructive?
          true
        end

        def call
          return error("This action can only be performed on a single game.") if models.count != 1

          target_game = models.first

          source_game_id = fields[:source_game_id] || fields["source_game_id"]
          confirm_merge = fields[:confirm_merge] || fields["confirm_merge"]

          unless source_game_id.present?
            return error("Please select a game to merge.")
          end

          unless confirm_merge == "1" || confirm_merge == true
            return error("Please confirm you understand this action cannot be undone.")
          end

          source_game = ::Games::Game.find_by(id: source_game_id)

          unless source_game
            return error("Game with ID #{source_game_id} not found.")
          end

          if source_game.id == target_game.id
            return error("Cannot merge a game with itself. Please select a different game.")
          end

          source_title = source_game.title
          source_id = source_game.id

          merger = ::Games::Game::Merger.new(source: source_game, target: target_game)
          result = merger.call

          if result.success?
            message = "Successfully merged '#{source_title}' (ID: #{source_id}) into '#{target_game.title}'. The source game has been deleted."

            if merger.stats[:post_commit_error].present?
              warn "#{message} Note: search reindexing and ranking recalculation could not be " \
                "scheduled (#{merger.stats[:post_commit_error]}); they will need to be re-run."
            else
              succeed message
            end
          else
            error "Failed to merge games: #{result.errors.join(", ")}"
          end
        end
      end
    end
  end
end
