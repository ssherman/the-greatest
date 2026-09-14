# frozen_string_literal: true

require "test_helper"

module Services
  module RankingConfigurations
    class SaveTest < ActiveSupport::TestCase
      setup do
        @entry = ::RankingConfigurations::Registry.find(:books, "books")
        @config = ranking_configurations(:books_user)
        @config.update_columns(needs_refresh: false)
        @config.penalty_applications.destroy_all
        @on = penalties(:books_penalty)
        @off = penalties(:global_penalty)
        # @off is static; it is only in the catalogue while tagged on an active list.
        active = ::Books::List.create!(name: "Active tagged list", source: "T", status: :active)
        ::ListPenalty.create!(list: active, penalty: @off)
        @config.penalty_applications.create!(penalty: @on, value: 20)
        @current = {@on.id.to_s => {"enabled" => "1", "value" => "20"}}
      end

      test "renaming or sharing does not mark the configuration stale" do
        result = Save.call(config: @config, entry: @entry, attributes: {name: "Renamed", user_shared: true}, penalties: @current)

        assert result.success?, result.errors.inspect
        @config.reload
        assert_equal "Renamed", @config.name
        assert @config.user_shared?
        refute @config.needs_refresh?
      end

      test "changing a ranking setting marks the configuration stale" do
        result = Save.call(config: @config, entry: @entry, attributes: {exponent: 4.0}, penalties: @current)

        assert result.success?
        assert @config.reload.needs_refresh?
      end

      test "enabling a penalty creates its application and marks stale" do
        submitted = @current.merge(@off.id.to_s => {"enabled" => "1", "value" => "55"})

        result = Save.call(config: @config, entry: @entry, attributes: {}, penalties: submitted)

        assert result.success?, result.errors.inspect
        assert_equal 55, @config.penalty_applications.find_by(penalty: @off).value
        assert @config.reload.needs_refresh?
      end

      test "changing a value updates the application and marks stale" do
        submitted = {@on.id.to_s => {"enabled" => "1", "value" => "45"}}

        Save.call(config: @config, entry: @entry, attributes: {}, penalties: submitted)

        assert_equal 45, @config.penalty_applications.find_by(penalty: @on).value
        assert @config.reload.needs_refresh?
      end

      test "disabling a penalty destroys its application and marks stale" do
        result = Save.call(config: @config, entry: @entry, attributes: {}, penalties: {})

        assert result.success?
        assert_nil @config.penalty_applications.find_by(penalty: @on)
        assert @config.reload.needs_refresh?
      end

      test "an unchanged penalty set does not mark stale" do
        result = Save.call(config: @config, entry: @entry, attributes: {description: "same math"}, penalties: @current)

        assert result.success?
        refute @config.reload.needs_refresh?
      end

      test "one invalid penalty value rolls back every change" do
        submitted = @current.merge(@off.id.to_s => {"enabled" => "1", "value" => "500"})

        result = Save.call(config: @config, entry: @entry, attributes: {name: "Should not persist"}, penalties: submitted)

        refute result.success?
        assert result.errors.any? { |message| message.include?("Value") }
        @config.reload
        assert_equal "User Books Ranking", @config.name
        assert_nil @config.penalty_applications.find_by(penalty: @off)
        refute @config.needs_refresh?
      end

      test "an invalid setting returns the record with errors" do
        result = Save.call(config: @config, entry: @entry, attributes: {exponent: 50}, penalties: @current)

        refute result.success?
        assert result.data[:ranking_configuration].errors[:exponent].any?
      end

      test "user-specific penalties are never touched" do
        foreign = penalties(:user_penalty)
        submitted = @current.merge(foreign.id.to_s => {"enabled" => "1", "value" => "10"})

        Save.call(config: @config, entry: @entry, attributes: {}, penalties: submitted)

        assert_nil @config.penalty_applications.find_by(penalty: foreign)
      end
    end
  end
end
