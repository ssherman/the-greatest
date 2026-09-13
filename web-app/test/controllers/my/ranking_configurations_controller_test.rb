require "test_helper"

class My::RankingConfigurationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! Rails.application.config.domains[:books]
    @owner = users(:regular_user)
    @stranger = users(:editor_user)
    @config = ranking_configurations(:books_user)
    @shared = ranking_configurations(:books_user_shared)
    @primary = ranking_configurations(:books_global)
  end

  def valid_attributes(overrides = {})
    {
      name: "Mine", description: "A description", user_shared: "0",
      exponent: "3.0", bonus_pool_percentage: "3.0", min_list_weight: "0",
      apply_list_dates_penalty: "1", max_list_dates_penalty_age: "50", max_list_dates_penalty_percentage: "80"
    }.merge(overrides)
  end

  # Sidekiq runs inline in tests; the refresh job would really calculate.
  # fake! pushes onto RefreshJob.jobs instead so tests can count enqueues.
  def with_fake_sidekiq
    Sidekiq::Testing.fake! do
      RankingConfigurations::RefreshJob.clear
      yield
    end
  end

  def fill_to_cap(user)
    existing = RankingConfiguration.where(type: "Books::RankingConfiguration", user_id: user.id).count
    (RankingConfiguration::MAX_PER_USER - existing).times do |i|
      Books::RankingConfiguration.create!(name: "Cap #{i}", global: false, user: user, min_list_weight: 0)
    end
  end

  # --- access ---

  test "every page requires sign-in" do
    get my_ranking_configurations_path
    assert_redirected_to "/"
    get new_my_ranking_configuration_path
    assert_redirected_to "/"
    get my_ranking_configuration_path(@config)
    assert_redirected_to "/"
    post my_ranking_configurations_path, params: {ranking_configuration: valid_attributes}
    assert_redirected_to "/"
  end

  test "the surface 404s on a domain with no registry entry" do
    host! Rails.application.config.domains[:games]
    sign_in_as @owner, stub_auth: true

    get my_ranking_configurations_path
    assert_response :not_found
  end

  test "pages are never cached" do
    sign_in_as @owner, stub_auth: true
    get my_ranking_configurations_path
    assert_match "no-store", response.headers["Cache-Control"].to_s
  end

  # --- index ---

  test "index lists only the current user's configurations for this domain" do
    sign_in_as @owner, stub_auth: true

    get my_ranking_configurations_path

    assert_response :success
    ids = @controller.view_assigns["ranking_configurations"].map(&:id)
    assert_equal [@config.id, @shared.id].sort, ids.sort
    refute @controller.view_assigns["at_limit"]
  end

  test "index flags the cap" do
    fill_to_cap(@owner)
    sign_in_as @owner, stub_auth: true

    get my_ranking_configurations_path

    assert @controller.view_assigns["at_limit"]
  end

  # --- new ---

  test "new pre-fills settings and penalties from the official configuration" do
    @primary.update_columns(exponent: 2.5, min_list_weight: -50)
    sign_in_as @owner, stub_auth: true

    get new_my_ranking_configuration_path

    assert_response :success
    form = @controller.view_assigns["ranking_configuration"]
    assert_equal 2.5, form.exponent.to_f
    assert_equal 0, form.min_list_weight
    assert_equal :official, @controller.view_assigns["start"]
    enabled = @controller.view_assigns["penalty_groups"].flat_map(&:rows).select(&:enabled).map { |row| row.penalty.id }
    assert_equal @primary.penalty_applications.pluck(:penalty_id).sort, enabled.sort
    assert_equal @primary.ranked_lists.count, @controller.view_assigns["official_list_count"]
  end

  test "new with start=scratch pre-fills defaults with every penalty off" do
    sign_in_as @owner, stub_auth: true

    get new_my_ranking_configuration_path(start: "scratch")

    assert_response :success
    assert_equal :scratch, @controller.view_assigns["start"]
    assert_equal 3.0, @controller.view_assigns["ranking_configuration"].exponent.to_f
    assert @controller.view_assigns["penalty_groups"].flat_map(&:rows).none?(&:enabled)
  end

  # --- create ---

  test "create builds the configuration, seeds the official lists, applies penalties, queues the first refresh" do
    list = Books::List.create!(name: "Official", source: "T", status: :active)
    RankedList.create!(list: list, ranking_configuration: @primary, weight: 70)
    penalty = penalties(:books_penalty)
    sign_in_as @owner, stub_auth: true

    with_fake_sidekiq do
      assert_difference "RankingConfiguration.count", 1 do
        post my_ranking_configurations_path, params: {
          start: "official", seed_lists: "1",
          ranking_configuration: valid_attributes,
          penalties: {penalty.id.to_s => {enabled: "1", value: "33"}}
        }
      end
      assert_equal 1, RankingConfigurations::RefreshJob.jobs.size
    end

    created = RankingConfiguration.order(:id).last
    assert_redirected_to my_ranking_configuration_path(created)
    assert flash[:notice].present?
    assert_equal @owner, created.user
    assert_equal @primary.ranked_lists.count, created.ranked_lists.count
    assert_includes created.ranked_lists.pluck(:list_id), list.id
    assert_equal 33, created.penalty_applications.find_by(penalty: penalty).value
    assert created.refresh_queued?
  end

  test "create with start=scratch seeds nothing and inherits nothing" do
    sign_in_as @owner, stub_auth: true

    with_fake_sidekiq do
      post my_ranking_configurations_path, params: {start: "scratch", ranking_configuration: valid_attributes}
    end

    created = RankingConfiguration.order(:id).last
    assert_empty created.ranked_lists
    assert_empty created.penalty_applications
    assert_nil created.inherited_from_id
  end

  test "create re-renders the form on a validation failure" do
    sign_in_as @owner, stub_auth: true

    with_fake_sidekiq do
      assert_no_difference "RankingConfiguration.count" do
        post my_ranking_configurations_path, params: {start: "official", ranking_configuration: valid_attributes(name: "")}
      end
      assert_empty RankingConfigurations::RefreshJob.jobs
    end
    assert_response :unprocessable_entity
  end

  test "create refuses the sixth configuration" do
    fill_to_cap(@owner)
    sign_in_as @owner, stub_auth: true

    assert_no_difference "RankingConfiguration.count" do
      post my_ranking_configurations_path, params: {start: "scratch", ranking_configuration: valid_attributes}
    end
    assert_response :unprocessable_entity
  end

  # --- show ---

  test "show renders for the owner" do
    sign_in_as @owner, stub_auth: true

    get my_ranking_configuration_path(@config)

    assert_response :success
    assert_equal @config, @controller.view_assigns["ranking_configuration"]
  end

  test "show 404s for a non-owner, a shared configuration included, and for a global one" do
    sign_in_as @stranger, stub_auth: true
    get my_ranking_configuration_path(@config)
    assert_response :not_found
    get my_ranking_configuration_path(@shared)
    assert_response :not_found

    sign_in_as @owner, stub_auth: true
    get my_ranking_configuration_path(@primary)
    assert_response :not_found
  end

  # --- edit / update ---

  test "edit renders for the owner with the configuration's own penalty values" do
    @config.penalty_applications.create!(penalty: penalties(:books_penalty), value: 12)
    sign_in_as @owner, stub_auth: true

    get edit_my_ranking_configuration_path(@config)

    assert_response :success
    row = @controller.view_assigns["penalty_groups"].flat_map(&:rows).find { |r| r.penalty == penalties(:books_penalty) }
    assert row.enabled
    assert_equal 12, row.value
  end

  test "update saves settings and marks the configuration stale" do
    sign_in_as @owner, stub_auth: true

    patch my_ranking_configuration_path(@config), params: {ranking_configuration: valid_attributes(name: "Renamed", exponent: "4.0")}

    assert_redirected_to my_ranking_configuration_path(@config)
    assert flash[:notice].present?
    @config.reload
    assert_equal "Renamed", @config.name
    assert_equal 4.0, @config.exponent.to_f
    assert @config.needs_refresh?
  end

  test "update re-renders on a validation failure" do
    sign_in_as @owner, stub_auth: true

    patch my_ranking_configuration_path(@config), params: {ranking_configuration: valid_attributes(exponent: "50")}

    assert_response :unprocessable_entity
  end

  test "update ignores penalty ids outside the catalogue" do
    foreign = penalties(:user_penalty)
    @config.penalty_applications.where(penalty: foreign).destroy_all
    sign_in_as @owner, stub_auth: true

    patch my_ranking_configuration_path(@config), params: {
      ranking_configuration: valid_attributes,
      penalties: {foreign.id.to_s => {enabled: "1", value: "10"}, "999999" => {enabled: "1", value: "10"}}
    }

    assert_redirected_to my_ranking_configuration_path(@config)
    assert_nil @config.penalty_applications.find_by(penalty: foreign)
  end

  test "a non-owner cannot update or destroy" do
    sign_in_as @stranger, stub_auth: true

    patch my_ranking_configuration_path(@config), params: {ranking_configuration: valid_attributes(name: "Hijacked")}
    assert_response :not_found
    delete my_ranking_configuration_path(@config)
    assert_response :not_found

    assert_equal "User Books Ranking", @config.reload.name
  end

  # --- destroy ---

  test "destroy removes the configuration and its children" do
    @config.penalty_applications.create!(penalty: penalties(:books_penalty), value: 5)
    @config.ranked_lists.create!(list: Books::List.create!(name: "L", source: "T", status: :active))
    sign_in_as @owner, stub_auth: true

    assert_difference ["RankingConfiguration.count", "RankedList.count"], -1 do
      delete my_ranking_configuration_path(@config)
    end
    assert_redirected_to my_ranking_configurations_path
    assert flash[:notice].present?
  end

  # --- refresh (spec §7) ---

  test "refresh claims the lock, enqueues the job and redirects with a notice" do
    sign_in_as @owner, stub_auth: true

    with_fake_sidekiq do
      post refresh_my_ranking_configuration_path(@config)
      assert_equal 1, RankingConfigurations::RefreshJob.jobs.size
    end

    assert_redirected_to my_ranking_configuration_path(@config)
    assert flash[:notice].present?
    assert @config.reload.refresh_queued?
  end

  test "refresh is rejected while a run is in progress and does not spend the daily allowance" do
    @config.update_columns(refresh_status: RankingConfiguration.refresh_statuses[:running], refresh_requested_at: Time.current)
    sign_in_as @owner, stub_auth: true

    with_fake_sidekiq do
      (My::RankingConfigurationsController::REFRESH_LIMIT + 2).times do
        post refresh_my_ranking_configuration_path(@config)
        assert_redirected_to my_ranking_configuration_path(@config)
        assert flash[:alert].present?
      end
      assert_empty RankingConfigurations::RefreshJob.jobs
      assert @config.reload.refresh_running?

      @config.update_columns(refresh_status: RankingConfiguration.refresh_statuses[:idle])
      post refresh_my_ranking_configuration_path(@config)
      assert flash[:notice].present?, "the rejected clicks did not count against the limit"
      assert_equal 1, RankingConfigurations::RefreshJob.jobs.size
    end
  end

  test "refresh reclaims a run abandoned longer than the stale window" do
    @config.update_columns(refresh_status: RankingConfiguration.refresh_statuses[:running],
      refresh_requested_at: (RankingConfiguration::REFRESH_STALE_AFTER + 1.minute).ago)
    sign_in_as @owner, stub_auth: true

    with_fake_sidekiq do
      post refresh_my_ranking_configuration_path(@config)
      assert_equal 1, RankingConfigurations::RefreshJob.jobs.size
    end
    assert flash[:notice].present?
    assert @config.reload.refresh_queued?
  end

  test "the sixth refresh in a day is limited and claims nothing" do
    sign_in_as @owner, stub_auth: true

    with_fake_sidekiq do
      My::RankingConfigurationsController::REFRESH_LIMIT.times do
        @config.update_columns(refresh_status: RankingConfiguration.refresh_statuses[:idle])
        post refresh_my_ranking_configuration_path(@config)
        assert flash[:notice].present?
      end

      @config.update_columns(refresh_status: RankingConfiguration.refresh_statuses[:idle])
      post refresh_my_ranking_configuration_path(@config)

      assert_redirected_to my_ranking_configuration_path(@config)
      assert flash[:alert].present?
      assert @config.reload.refresh_idle?
      assert_equal My::RankingConfigurationsController::REFRESH_LIMIT, RankingConfigurations::RefreshJob.jobs.size
    end
  end

  test "the daily limit is per user" do
    sign_in_as @owner, stub_auth: true
    with_fake_sidekiq do
      My::RankingConfigurationsController::REFRESH_LIMIT.times do
        @config.update_columns(refresh_status: RankingConfiguration.refresh_statuses[:idle])
        post refresh_my_ranking_configuration_path(@config)
      end
      @config.update_columns(refresh_status: RankingConfiguration.refresh_statuses[:idle])
      post refresh_my_ranking_configuration_path(@config)
      assert flash[:alert].present?

      other_config = Books::RankingConfiguration.create!(name: "Theirs", global: false, user: @stranger, min_list_weight: 0)
      sign_in_as @stranger, stub_auth: true
      post refresh_my_ranking_configuration_path(other_config)
      assert flash[:notice].present?
      assert other_config.reload.refresh_queued?
    end
  end

  test "a non-owner cannot refresh" do
    sign_in_as @stranger, stub_auth: true

    with_fake_sidekiq do
      post refresh_my_ranking_configuration_path(@config)
      assert_response :not_found
      assert_empty RankingConfigurations::RefreshJob.jobs
    end
  end

  # --- state ---

  test "state returns the refresh state as JSON for the owner" do
    @config.update_columns(refresh_status: RankingConfiguration.refresh_statuses[:failed],
      needs_refresh: true, last_refresh_error: "boom")
    sign_in_as @owner, stub_auth: true

    get state_my_ranking_configuration_path(@config), as: :json

    assert_response :success
    assert_match "no-store", response.headers["Cache-Control"].to_s
    body = response.parsed_body
    assert_equal "failed", body["refresh_status"]
    assert_equal true, body["needs_refresh"]
    assert_equal "boom", body["last_refresh_error"]
    assert_nil body["last_refreshed_at"]
  end

  test "state is 401 anonymous and 404 for a non-owner" do
    get state_my_ranking_configuration_path(@config), as: :json
    assert_response :unauthorized

    sign_in_as @stranger, stub_auth: true
    get state_my_ranking_configuration_path(@config), as: :json
    assert_response :not_found
  end
end
