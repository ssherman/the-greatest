require "test_helper"

module Games
  class GamesControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev.thegreatest.games"
    end

    def attach_cover(game, metadata)
      image = Image.new(parent: game, primary: true)
      image.file.attach(ActiveStorage::Blob.create_and_upload!(
        io: File.open(file_fixture("test_image.png")), filename: "c.png",
        content_type: "image/png", metadata: metadata
      ))
      image.save!
      image
    end

    test "a qualifying cover becomes og:image with the title as alt" do
      game = games_games(:breath_of_the_wild)
      image = attach_cover(game, {width: 300, height: 400, analyzed: true})

      get game_path(game)

      assert_response :success
      cdn = Rails.application.config.domain_settings[:games][:images_cdn][:default]
      assert_equal "#{cdn}/#{image.file.key}", css_select("meta[property='og:image']").first["content"]
      assert_select "meta[property='og:image:alt'][content=?]", game.title
      assert_select "meta[name='twitter:card'][content=summary]"
    end

    test "og:title is title - developers with no site suffix" do
      game = games_games(:breath_of_the_wild)
      developers = game.game_companies.select(&:developer?).map { |gc| gc.company.name }.join(", ")
      assert_predicate developers, :present?

      get game_path(game)

      assert_select "meta[property='og:title'][content=?]", "#{game.title} - #{developers}"
    end

    test "og:title is the bare title for a game with no developers" do
      game = games_games(:breath_of_the_wild)
      game.game_companies.destroy_all

      get game_path(game)

      assert_response :success
      assert_select "meta[property='og:title'][content=?]", game.title
    end

    test "a game without a cover has no og:image" do
      game = games_games(:breath_of_the_wild)
      game.images.destroy_all

      get game_path(game)

      assert_response :success
      assert_select "meta[property='og:image']", 0
      assert_select "meta[property='og:image:alt']", 0
    end

    test "a cover without measured dimensions has no og:image" do
      game = games_games(:breath_of_the_wild)
      game.images.destroy_all
      attach_cover(game, {identified: true})

      get game_path(game)

      assert_response :success
      assert_select "meta[property='og:image']", 0
    end

    test "should get show with default ranking configuration" do
      get game_path(games_games(:breath_of_the_wild))
      assert_response :success
      assert_select "h1", "The Legend of Zelda: Breath of the Wild"
      assert_select "title", /The Legend of Zelda: Breath of the Wild/
    end

    test "should get show with specific ranking configuration" do
      get game_path(games_games(:breath_of_the_wild), ranking_configuration_id: ranking_configurations(:games_global).id)
      assert_response :success
      assert_select "h1", "The Legend of Zelda: Breath of the Wild"
    end

    test "should get show by slug" do
      get game_path("the-legend-of-zelda-breath-of-the-wild")
      assert_response :success
      assert_select "h1", "The Legend of Zelda: Breath of the Wild"
    end

    test "should display release year" do
      get game_path(games_games(:breath_of_the_wild))
      assert_response :success
      assert_match "2017", response.body
    end

    test "should return 404 for non-existent game" do
      get game_path("non-existent-game")
      assert_response :not_found
    end

    test "should display non-main game type" do
      get game_path(games_games(:resident_evil_4_remake))
      assert_response :success
      assert_match "Remake", response.body
    end

    test "should show platforms section" do
      get game_path(games_games(:resident_evil_4_remake))
      assert_response :success
      assert_select "h2", /Platforms/
    end

    test "should show series section for games in a series" do
      get game_path(games_games(:breath_of_the_wild))
      assert_response :success
      assert_select "h2", /Zelda Series/
    end

    test "show renders the game's primary description" do
      game = games_games(:breath_of_the_wild)
      get game_path(game)

      assert_response :success
      assert_includes response.body, descriptions(:botw_igdb).content
    end

    test "show renders successfully for a game with no description" do
      game = games_games(:resident_evil_4)
      assert_empty game.descriptions

      get game_path(game)
      assert_response :success
    end

    test "show excludes lists that are not active from list_items" do
      game = games_games(:breath_of_the_wild)
      rc = ranking_configurations(:games_global)
      active_list = Games::List.create!(name: "Active List", status: :active)
      unapproved_list = Games::List.create!(name: "Unapproved List", status: :unapproved)
      RankedList.create!(list: active_list, ranking_configuration: rc, weight: 10)
      RankedList.create!(list: unapproved_list, ranking_configuration: rc, weight: 10)
      ListItem.create!(list: active_list, listable: game, position: 1)
      ListItem.create!(list: unapproved_list, listable: game, position: 1)

      get game_path(game)

      assert_response :success
      list_ids = @controller.view_assigns["list_items"].map(&:list_id)
      assert_includes list_ids, active_list.id
      assert_not_includes list_ids, unapproved_list.id
    end
  end
end
