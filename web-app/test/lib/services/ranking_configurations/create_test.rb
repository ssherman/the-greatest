# frozen_string_literal: true

require "test_helper"

module Services
  module RankingConfigurations
    class CreateTest < ActiveSupport::TestCase
      setup do
        @user = users(:editor_user) # owns no configurations in fixtures
        @entry = ::RankingConfigurations::Registry.find(:books, "books")
        @primary = ranking_configurations(:books_global)
        @primary.update_columns(min_list_weight: -50, exponent: 2.5, bonus_pool_percentage: 4.0)
        @official_list = ::Books::List.create!(name: "Official", source: "Test", status: :active)
        ::RankedList.create!(list: @official_list, ranking_configuration: @primary, weight: 70)
        @attributes = {name: "My ranking", description: "Mine", user_shared: false}
        ::RankingConfigurations::RefreshJob.stubs(:perform_async)
      end

      test "official start copies settings, clamps min_list_weight, links inherited_from and seeds every list" do
        result = Create.call(user: @user, entry: @entry, attributes: @attributes, penalties: {}, start: :official, seed_lists: true)

        assert result.success?, result.errors.inspect
        config = result.data[:ranking_configuration]
        assert config.persisted?
        assert_equal @user, config.user
        refute config.global?
        refute config.primary?
        assert_equal @primary.id, config.inherited_from_id
        assert_equal 2.5, config.exponent.to_f
        assert_equal 4.0, config.bonus_pool_percentage.to_f
        assert_equal 0, config.min_list_weight, "the primary's -50 is clamped to its weight_floor"
        assert_nil config.published_at
        assert_nil config.year
        assert_nil config.list_limit
        assert config.needs_refresh?
        assert_equal @primary.ranked_lists.pluck(:list_id).sort, config.ranked_lists.pluck(:list_id).sort
      end

      test "official start without seed_lists copies nothing into ranked_lists" do
        result = Create.call(user: @user, entry: @entry, attributes: @attributes, penalties: {}, start: :official, seed_lists: false)

        assert result.success?
        assert_empty result.data[:ranking_configuration].ranked_lists
      end

      test "scratch start uses model defaults, no inheritance, no lists, no penalties" do
        result = Create.call(user: @user, entry: @entry, attributes: @attributes, penalties: {}, start: :scratch, seed_lists: true)

        assert result.success?, result.errors.inspect
        config = result.data[:ranking_configuration]
        assert_nil config.inherited_from_id
        assert_equal 3.0, config.exponent.to_f
        assert_empty config.ranked_lists
        assert_empty config.penalty_applications
        assert config.needs_refresh?
      end

      test "writes one penalty application per enabled catalogue penalty and ignores foreign ids" do
        enabled = penalties(:books_penalty)
        skipped = penalties(:global_penalty)
        foreign = penalties(:user_penalty)
        submitted = {
          enabled.id.to_s => {"enabled" => "1", "value" => "35"},
          skipped.id.to_s => {"value" => "90"},
          foreign.id.to_s => {"enabled" => "1", "value" => "10"}
        }

        result = Create.call(user: @user, entry: @entry, attributes: @attributes, penalties: submitted, start: :scratch, seed_lists: false)

        assert result.success?, result.errors.inspect
        applications = result.data[:ranking_configuration].penalty_applications.index_by(&:penalty_id)
        assert_equal 35, applications[enabled.id].value
        assert_nil applications[skipped.id]
        assert_nil applications[foreign.id]
      end

      test "the submitted attributes override the copied ones" do
        result = Create.call(user: @user, entry: @entry, attributes: @attributes.merge(exponent: 1.5, apply_list_dates_penalty: false), penalties: {}, start: :official, seed_lists: false)

        config = result.data[:ranking_configuration]
        assert_equal 1.5, config.exponent.to_f
        refute config.apply_list_dates_penalty?
      end

      test "requests the first refresh after the transaction" do
        ::RankingConfigurations::RefreshJob.unstub(:perform_async)
        ::RankingConfigurations::RefreshJob.expects(:perform_async).once

        result = Create.call(user: @user, entry: @entry, attributes: @attributes, penalties: {}, start: :official, seed_lists: true)

        assert result.data[:ranking_configuration].reload.refresh_queued?
      end

      test "a validation failure returns the record with errors and persists nothing" do
        ::RankingConfigurations::RefreshJob.expects(:perform_async).never

        assert_no_difference ["::RankingConfiguration.count", "::RankedList.count", "::PenaltyApplication.count"] do
          result = Create.call(user: @user, entry: @entry, attributes: @attributes.merge(name: ""), penalties: {}, start: :official, seed_lists: true)

          refute result.success?
          assert_includes result.errors, "Name can't be blank"
          assert result.data[:ranking_configuration].errors[:name].any?
        end
      end

      test "an invalid penalty value rolls the whole create back" do
        submitted = {penalties(:books_penalty).id.to_s => {"enabled" => "1", "value" => "101"}}

        assert_no_difference ["::RankingConfiguration.count", "::PenaltyApplication.count"] do
          result = Create.call(user: @user, entry: @entry, attributes: @attributes, penalties: submitted, start: :official, seed_lists: true)

          refute result.success?
          assert result.errors.any? { |message| message.include?("Value") }
        end
      end

      test "an invalid penalty value adds errors to the returned configuration" do
        submitted = {penalties(:books_penalty).id.to_s => {"enabled" => "1", "value" => "101"}}

        result = Create.call(user: @user, entry: @entry, attributes: @attributes, penalties: submitted, start: :official, seed_lists: true)

        refute result.success?
        assert result.data[:ranking_configuration].errors[:base].any? { |message| message.include?("Value") }
      end

      test "holds the owner's row lock while creating so the cap cannot be raced" do
        assert_queries_match(/FROM "users" WHERE "users"."id" = \$1 LIMIT \$2 FOR UPDATE/) do
          Create.call(user: @user, entry: @entry, attributes: @attributes, penalties: {}, start: :scratch, seed_lists: false)
        end
      end

      test "the fifth configuration succeeds and the sixth is refused" do
        (::RankingConfiguration::MAX_PER_USER - 1).times do |i|
          ::Books::RankingConfiguration.create!(name: "Existing #{i}", global: false, user: @user, min_list_weight: 0)
        end

        assert Create.call(user: @user, entry: @entry, attributes: @attributes, penalties: {}, start: :scratch, seed_lists: false).success?

        result = Create.call(user: @user, entry: @entry, attributes: @attributes, penalties: {}, start: :scratch, seed_lists: false)
        refute result.success?
        assert_includes result.errors, "You can have at most #{::RankingConfiguration::MAX_PER_USER} rankings"
      end

      test "official start fails cleanly when the domain has no primary" do
        @primary.update_columns(primary: false)

        result = Create.call(user: @user, entry: @entry, attributes: @attributes, penalties: {}, start: :official, seed_lists: true)

        refute result.success?
        assert_includes result.errors, "There is no official ranking to copy from"
      end
    end
  end
end
