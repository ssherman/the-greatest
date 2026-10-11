# frozen_string_literal: true

require "test_helper"
require "rake"

class E2eRakeTest < ActiveSupport::TestCase
  PREPARE = Services::E2e::Prepare
  ENV_KEYS = %w[PLAYWRIGHT_ADMIN_EMAIL PLAYWRIGHT_USER_EMAIL PLAYWRIGHT_MEMBER_EMAIL].freeze

  setup do
    # Load only this one rake file (see penalties_rake_test.rb for why not
    # Rails.application.load_tasks).
    unless Rake::Task.task_defined?("e2e:prepare")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/e2e.rake").to_s }
    end
    @previous = ENV_KEYS.index_with { |key| ENV[key] }
    ENV["PLAYWRIGHT_ADMIN_EMAIL"] = "a@example.com"
    ENV["PLAYWRIGHT_USER_EMAIL"] = "u@example.com"
    ENV["PLAYWRIGHT_MEMBER_EMAIL"] = "m@example.com"
  end

  teardown do
    @previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def invoke(name)
    task = Rake::Task[name]
    task.reenable
    task.invoke
  end

  test "e2e:prepare hands the three env emails and the manifest path to the service" do
    PREPARE.expects(:call).with(has_entries(
      emails: {admin: "a@example.com", user: "u@example.com", member: "m@example.com"},
      manifest_path: Rails.root.join("e2e", ".auth", "seed.json")
    )).returns(PREPARE::Result.new(success?: true, data: {}, errors: []))

    invoke("e2e:prepare")
  end

  test "e2e:prepare aborts with the service's errors, one per line" do
    PREPARE.stubs(:call).returns(PREPARE::Result.new(success?: false, data: nil, errors: ["no User for a@example.com", "stripe: down"]))

    assert_output(nil, /no User for a@example.com\nstripe: down/) do
      assert_raises(SystemExit) { invoke("e2e:prepare") }
    end
  end

  test "e2e:rate_limit_reset clears the store" do
    store = Rails.application.config.x.rate_limit_store
    store.write("contact:127.0.0.1", 5)

    assert_output(/rate limiter cleared/) { invoke("e2e:rate_limit_reset") }
    assert_nil store.read("contact:127.0.0.1")
  end

  test "the four manual account tasks are gone" do
    %w[e2e:admin e2e:member e2e:my_reviews e2e:books_public_list].each do |name|
      assert_not Rake::Task.task_defined?(name), "#{name} should have been deleted; prepare replaces it"
    end
  end
end
