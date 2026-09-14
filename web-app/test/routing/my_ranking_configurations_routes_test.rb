require "test_helper"

class MyRankingConfigurationsRoutesTest < ActionDispatch::IntegrationTest
  HOST = Rails.application.config.domains[:books]

  test "my rankings routes resolve on the books host" do
    base = "http://#{HOST}"
    assert_routing({method: :get, path: "#{base}/my/rankings"},
      controller: "my/ranking_configurations", action: "index")
    assert_routing({method: :get, path: "#{base}/my/rankings/new"},
      controller: "my/ranking_configurations", action: "new")
    assert_routing({method: :post, path: "#{base}/my/rankings"},
      controller: "my/ranking_configurations", action: "create")
    assert_routing({method: :get, path: "#{base}/my/rankings/12"},
      controller: "my/ranking_configurations", action: "show", id: "12")
    assert_routing({method: :get, path: "#{base}/my/rankings/12/edit"},
      controller: "my/ranking_configurations", action: "edit", id: "12")
    assert_routing({method: :patch, path: "#{base}/my/rankings/12"},
      controller: "my/ranking_configurations", action: "update", id: "12")
    assert_routing({method: :delete, path: "#{base}/my/rankings/12"},
      controller: "my/ranking_configurations", action: "destroy", id: "12")
    assert_routing({method: :post, path: "#{base}/my/rankings/12/refresh"},
      controller: "my/ranking_configurations", action: "refresh", id: "12")
    assert_routing({method: :get, path: "#{base}/my/rankings/12/state"},
      controller: "my/ranking_configurations", action: "state", id: "12")
    assert_routing({method: :get, path: "#{base}/my/rankings/12/lists"},
      controller: "my/ranking_configurations/lists", action: "index", ranking_configuration_id: "12")
    assert_routing({method: :get, path: "#{base}/my/rankings/12/lists/search"},
      controller: "my/ranking_configurations/lists", action: "search", ranking_configuration_id: "12")
    assert_routing({method: :post, path: "#{base}/my/rankings/12/lists"},
      controller: "my/ranking_configurations/lists", action: "create", ranking_configuration_id: "12")
    assert_routing({method: :post, path: "#{base}/my/rankings/12/lists/add_missing"},
      controller: "my/ranking_configurations/lists", action: "add_missing", ranking_configuration_id: "12")
    assert_routing({method: :delete, path: "#{base}/my/rankings/12/lists/34"},
      controller: "my/ranking_configurations/lists", action: "destroy", ranking_configuration_id: "12", list_id: "34")
  end

  test "non-numeric ids do not route" do
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/my/rankings/abc", method: :get)
    end
  end
end
