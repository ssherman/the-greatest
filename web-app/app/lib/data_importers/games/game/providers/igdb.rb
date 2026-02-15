# frozen_string_literal: true

module DataImporters
  module Games
    module Game
      module Providers
        # IGDB provider for Games::Game data
        # Fetches game information from IGDB API and populates the game record
        # including companies, platforms, and categories
        class Igdb < DataImporters::ProviderBase
          # IGDB category to game_type enum mapping
          # See: https://api-docs.igdb.com/#game-enums
          IGDB_CATEGORY_MAP = {
            0 => :main_game,
            1 => :dlc,
            2 => :expansion,
            3 => :bundle,
            4 => :standalone_expansion,
            5 => :mod,
            6 => :episode,
            7 => :season,
            8 => :remake,
            9 => :remaster,
            10 => :expanded_game,
            11 => :port
          }.freeze

          # Populates a game with IGDB data
          #
          # @param game [Games::Game] the game to enrich
          # @param query [ImportQuery] contains igdb_id (may be nil for item-based imports)
          # @return [ProviderResult] success or failure result
          def populate(game, query:)
            # Get IGDB ID from query or from existing identifier
            igdb_id = resolve_igdb_id(game, query)
            return failure_result(errors: ["No IGDB ID available"]) unless igdb_id

            api_result = search_service.find_with_details(igdb_id)

            return failure_result(errors: api_result[:errors]) unless api_result[:success]

            games_data = api_result[:data]
            return failure_result(errors: ["Game not found in IGDB"]) if games_data.empty?

            game_data = games_data.first

            populate_game_data(game, game_data)
            create_identifier(game, igdb_id)
            import_companies(game, game_data)
            import_platforms(game, game_data)
            import_categories(game, game_data)

            success_result(data_populated: data_fields_populated(game_data))
          rescue => e
            failure_result(errors: ["IGDB error: #{e.message}"])
          end

          private

          def search_service
            @search_service ||= ::Games::Igdb::Search::GameSearch.new
          end

          # Resolves IGDB ID from query or existing identifier on game
          def resolve_igdb_id(game, query)
            # First check query
            return query.igdb_id if query&.igdb_id.present?

            # Fall back to existing identifier on game
            game.identifiers.find_by(identifier_type: :games_igdb_id)&.value&.to_i
          end

          # Maps IGDB game data to model attributes
          def populate_game_data(game, game_data)
            game.title = game_data["name"] if game_data["name"].present?
            game.description = game_data["summary"] if game_data["summary"].present?

            # Extract year from IGDB first_release_date (Unix timestamp)
            if game_data["first_release_date"].present?
              game.release_year = Time.at(game_data["first_release_date"]).year
            end

            # Map IGDB category to game_type
            if game_data["category"].present?
              game.game_type = map_igdb_category(game_data["category"])
            end
          end

          def map_igdb_category(igdb_category)
            IGDB_CATEGORY_MAP[igdb_category] || :main_game
          end

          def create_identifier(game, igdb_id)
            game.identifiers.find_or_initialize_by(
              identifier_type: :games_igdb_id,
              value: igdb_id.to_s
            )
          end

          # Imports companies from IGDB involved_companies data
          # Recursively imports each company and creates GameCompany join records
          def import_companies(game, game_data)
            involved_companies = game_data["involved_companies"]
            return if involved_companies.blank?

            involved_companies.each do |ic|
              company_data = ic["company"]
              next unless company_data

              # Get company ID from nested data
              company_igdb_id = company_data.is_a?(Hash) ? company_data["id"] : company_data
              next unless company_igdb_id

              # Import company using Company::Importer
              company_result = DataImporters::Games::Company::Importer.call(igdb_id: company_igdb_id)

              if company_result.success?
                # Check if join record already exists
                existing_join = game.game_companies.find { |gc| gc.company_id == company_result.item.id }

                if existing_join
                  # Update existing join with explicit boolean values and save
                  existing_join.developer = ic["developer"] || false
                  existing_join.publisher = ic["publisher"] || false
                  existing_join.save! if existing_join.changed?
                else
                  # Create new join record
                  game.game_companies.build(
                    company: company_result.item,
                    developer: ic["developer"] || false,
                    publisher: ic["publisher"] || false
                  )
                end
              else
                Rails.logger.warn "Failed to import company #{company_igdb_id}: #{company_result.all_errors.join(", ")}"
              end
            end
          end

          # Imports platforms from IGDB platforms data
          # Finds existing platforms by slug or creates new ones
          def import_platforms(game, game_data)
            platforms_data = game_data["platforms"]
            return if platforms_data.blank?

            platforms_data.each do |platform_data|
              next unless platform_data.is_a?(Hash)

              slug = platform_data["slug"]
              name = platform_data["name"]
              next unless slug.present? && name.present?

              platform = find_or_create_platform(platform_data)

              # Only add if not already associated
              unless game.game_platforms.any? { |gp| gp.platform_id == platform.id }
                game.game_platforms.build(platform: platform)
              end
            end
          end

          def find_or_create_platform(platform_data)
            slug = platform_data["slug"]

            ::Games::Platform.find_by(slug: slug) || ::Games::Platform.create!(
              name: platform_data["name"],
              slug: slug,
              abbreviation: platform_data["abbreviation"],
              platform_family: infer_platform_family(platform_data)
            )
          end

          def infer_platform_family(platform_data)
            slug = platform_data["slug"].to_s.downcase
            name = platform_data["name"].to_s.downcase

            if slug.include?("ps") || name.include?("playstation")
              :playstation
            elsif slug.include?("xbox") || slug.include?("xone") || slug.include?("series-x")
              :xbox
            elsif slug.include?("switch") || slug.include?("wii") || name.include?("nintendo")
              :nintendo
            elsif slug.include?("win") || slug.include?("pc") || slug.include?("mac") || slug.include?("linux")
              :pc
            elsif slug.include?("ios") || slug.include?("android")
              :mobile
            else
              :other
            end
          end

          # Imports categories from IGDB genres, themes, game_modes, player_perspectives
          def import_categories(game, game_data)
            import_category_type(game, game_data, "genres", :genre)
            import_category_type(game, game_data, "themes", :theme)
            import_category_type(game, game_data, "game_modes", :game_mode)
            import_category_type(game, game_data, "player_perspectives", :player_perspective)
          end

          def import_category_type(game, game_data, field_name, category_type)
            categories_data = game_data[field_name]
            return if categories_data.blank?

            categories_data.each do |cat_data|
              category_name = cat_data.is_a?(Hash) ? cat_data["name"] : nil
              next unless category_name

              category = ::Games::Category.find_or_create_by!(
                name: category_name,
                category_type: category_type,
                import_source: :igdb
              )

              # Create CategoryItem join if not exists
              ::CategoryItem.find_or_create_by!(category: category, item: game)
            end
          end

          def data_fields_populated(game_data)
            fields = [:title, :igdb_id]
            fields << :description if game_data["summary"].present?
            fields << :release_year if game_data["first_release_date"].present?
            fields << :game_type if game_data["category"].present?
            fields << :companies if game_data["involved_companies"].present?
            fields << :platforms if game_data["platforms"].present?
            fields << :categories if game_data["genres"].present? || game_data["themes"].present?
            fields
          end
        end
      end
    end
  end
end
