require "test_helper"

class SystemMailerTest < ActionMailer::TestCase
  include ActiveJob::TestHelper

  setup { ENV["MAIL_FROM_ADDRESS"] = "noreply@example.org" }
  teardown { ENV.delete("MAIL_FROM_ADDRESS") }

  test "addresses the smoke email to the recipient it was given" do
    mail = SystemMailer.smoke_test(domain: :books, to: "ops@example.org")

    assert_equal ["ops@example.org"], mail.to
    assert_equal ["noreply@example.org"], mail.from
  end

  test "names the environment in the subject so a stray email is identifiable" do
    mail = SystemMailer.smoke_test(domain: :books, to: "ops@example.org")

    assert_match Rails.env, mail.subject
  end

  test "brands the smoke email for the domain it was given" do
    mail = SystemMailer.smoke_test(domain: :games, to: "ops@example.org")

    assert_match "The Greatest Games", mail.body.encoded
  end

  # THE IMPORTANT ONE. Sidekiq processes only the queues in config/sidekiq.yml.
  # If deliver_later enqueues onto any other queue, every email this app ever
  # sends is accepted, reported as sent, and silently never delivered.
  test "deliver_later enqueues onto a queue Sidekiq actually processes" do
    processed_queues = YAML.load_file(Rails.root.join("config/sidekiq.yml")).fetch(:queues)

    assert_enqueued_jobs 1 do
      SystemMailer.smoke_test(domain: :books, to: "ops@example.org").deliver_later
    end

    queue = enqueued_jobs.first[:queue]
    assert_includes processed_queues, queue,
      "deliver_later enqueued onto #{queue.inspect}, which is not in config/sidekiq.yml " \
      "(#{processed_queues.inspect}). Mail would be accepted and never delivered. " \
      "Set config.action_mailer.deliver_later_queue_name."
  end
end
