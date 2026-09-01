# frozen_string_literal: true

require "test_helper"

class GenerateDynamicListsJobTest < ActiveSupport::TestCase
  setup do
    @config = ranking_configurations(:books_year_2025)
  end

  test "calls the service for the given configuration" do
    Services::Lists::GenerateDynamicLists
      .expects(:call)
      .with(ranking_configuration: @config, recalculate_primary: true)
      .returns(Services::Lists::GenerateDynamicLists::Result.new(
        success?: true,
        data: {top_count: 2, overflow_count: 2, source_list_count: 1},
        errors: []
      ))

    GenerateDynamicListsJob.new.perform(@config.id)
  end

  test "passes recalculate_primary through" do
    Services::Lists::GenerateDynamicLists
      .expects(:call)
      .with(ranking_configuration: @config, recalculate_primary: false)
      .returns(Services::Lists::GenerateDynamicLists::Result.new(
        success?: true, data: {top_count: 0, overflow_count: 0, source_list_count: 0}, errors: []
      ))

    GenerateDynamicListsJob.new.perform(@config.id, false)
  end

  test "raises when the service fails so Sidekiq retries" do
    Services::Lists::GenerateDynamicLists
      .expects(:call)
      .returns(Services::Lists::GenerateDynamicLists::Result.new(
        success?: false, data: nil, errors: ["no year set"]
      ))

    error = assert_raises(RuntimeError) { GenerateDynamicListsJob.new.perform(@config.id) }
    assert_match(/no year set/, error.message)
  end

  test "raises when the configuration does not exist" do
    assert_raises(ActiveRecord::RecordNotFound) { GenerateDynamicListsJob.new.perform(-1) }
  end
end
