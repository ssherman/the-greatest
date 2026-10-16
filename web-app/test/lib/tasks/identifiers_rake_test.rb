# frozen_string_literal: true

require "test_helper"
require "rake"

class IdentifiersRakeTest < ActiveSupport::TestCase
  setup do
    # Load only this one rake file (see penalties_rake_test.rb for why not
    # Rails.application.load_tasks).
    unless Rake::Task.task_defined?("identifiers:mark_legacy")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/identifiers.rake").to_s }
    end
    Rake::Task["identifiers:mark_legacy"].reenable
  end

  test "mark_legacy prints the counts" do
    Services::Identifiers::MarkLegacy.expects(:call).returns(
      Services::Identifiers::MarkLegacy::Result.new(success?: true, data: {legacy: 12, open_library: 3}, errors: [])
    )

    assert_output(/12 identifiers marked legacy, 3 relabelled open_library/) { Rake::Task["identifiers:mark_legacy"].invoke }
  end
end
