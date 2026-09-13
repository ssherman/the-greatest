require "test_helper"

class MyRankingConfigurationsRoutesTest < ActionDispatch::IntegrationTest
  HOST = Rails.application.config.domains[:books]

  # `my/ranking_configurations/lists` is Task 12's controller and does not
  # exist yet -- these routes are declared now on purpose (see the task
  # brief) so `my_ranking_configuration_lists_path` and friends resolve
  # today. `assert_routing` resolves the matched controller class as part of
  # recognizing a route (RouteSet#recognize_path_with_request calls
  # `req.controller_class`), which raises ActionController::RoutingError for
  # a controller that has not been generated yet. That method assigns the
  # matched path parameters to the request before making that check, so a
  # route that matches but has no controller yet can still be confirmed by
  # rescuing the raised error and reading them off the request.
  def assert_route_pending_controller(method:, path:, controller:, action:, **params)
    env = Rack::MockRequest.env_for(path, method: method.to_s.upcase)
    req = ActionDispatch::Request.new(env)

    error = assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path_with_request(req, path, {})
    end
    assert_equal "A route matches #{path.inspect}, but references missing controller: My::RankingConfigurations::ListsController",
      error.message

    assert_equal controller, req.path_parameters[:controller]
    assert_equal action, req.path_parameters[:action]
    params.each { |key, value| assert_equal value, req.path_parameters[key] }
  end

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
    assert_route_pending_controller(method: :get, path: "#{base}/my/rankings/12/lists",
      controller: "my/ranking_configurations/lists", action: "index", ranking_configuration_id: "12")
    assert_route_pending_controller(method: :get, path: "#{base}/my/rankings/12/lists/search",
      controller: "my/ranking_configurations/lists", action: "search", ranking_configuration_id: "12")
    assert_route_pending_controller(method: :post, path: "#{base}/my/rankings/12/lists",
      controller: "my/ranking_configurations/lists", action: "create", ranking_configuration_id: "12")
    assert_route_pending_controller(method: :post, path: "#{base}/my/rankings/12/lists/add_missing",
      controller: "my/ranking_configurations/lists", action: "add_missing", ranking_configuration_id: "12")
    assert_route_pending_controller(method: :delete, path: "#{base}/my/rankings/12/lists/34",
      controller: "my/ranking_configurations/lists", action: "destroy", ranking_configuration_id: "12", list_id: "34")
  end

  test "non-numeric ids do not route" do
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/my/rankings/abc", method: :get)
    end
  end
end
