require "test_helper"

class ContactMessagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! "dev-new.thegreatestbooks.org"

    # The rate limit store is one MemoryStore shared by the whole process
    # (config/initializers/rate_limit_store.rb). Without clearing it, whichever
    # test runs after enough submissions trips the limit instead of the
    # dedicated rate-limit test below. Same fix as CorrectionsControllerTest.
    Rails.application.config.x.rate_limit_store.clear
  end

  def valid_params
    {contact_message: {email: "reader@example.org", message: "Hello there"}}
  end

  test "stores an anonymous message" do
    assert_difference "ContactMessage.count", 1 do
      post contact_messages_path, params: valid_params, as: :turbo_stream
    end

    assert_response :success
    message = ContactMessage.order(:id).last
    assert_equal "reader@example.org", message.email
    assert_predicate message, :books?
    assert_nil message.user
  end

  test "records the domain the message came from" do
    host! "dev.thegreatestmusic.org"

    post contact_messages_path, params: valid_params, as: :turbo_stream

    assert_predicate ContactMessage.order(:id).last, :music?
  end

  # The posted email is ignored for a signed-in visitor: the footer's HTML is
  # edge-cached and filled in by the client, so it is not evidence.
  test "uses the signed-in user's email over the posted one" do
    user = users(:regular_user)
    sign_in_as(user, stub_auth: true)

    post contact_messages_path,
      params: {contact_message: {email: "attacker@example.org", message: "Hello"}},
      as: :turbo_stream

    message = ContactMessage.order(:id).last
    assert_equal user.email, message.email
    assert_equal user, message.user
  end

  test "answers a successful submission with a turbo stream" do
    post contact_messages_path, params: valid_params, as: :turbo_stream

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_match(/contact_modal_body/, response.body)
  end

  test "answers a validation failure with a turbo stream, not a bare 422" do
    assert_no_difference "ContactMessage.count" do
      post contact_messages_path,
        params: {contact_message: {email: "reader@example.org", message: ""}},
        as: :turbo_stream
    end

    assert_response :unprocessable_entity
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_match(/contact_modal_body/, response.body)
  end

  # Previously the re-rendered form came back with empty fields: a visitor who
  # wrote 400 words and typed an address the browser accepts but the server
  # rejects (<input type=email> allows "shane@gmail"; EMAIL_FORMAT requires a
  # dot-TLD) got a 422 and their text was just gone.
  test "echoes the submitted message back after a validation failure" do
    post contact_messages_path,
      params: {contact_message: {email: "shane@gmail", message: "A very particular sentence."}},
      as: :turbo_stream

    assert_response :unprocessable_entity
    assert_match(/A very particular sentence\./, response.body)
  end

  test "echoes the anonymous visitor's posted email back after a validation failure" do
    post contact_messages_path,
      params: {contact_message: {email: "shane@gmail", message: "Hello there"}},
      as: :turbo_stream

    assert_response :unprocessable_entity
    assert_match(/value="shane@gmail"/, response.body)
  end

  # The posted email is never evidence for a signed-in visitor (same rule the
  # successful-submission test above covers) -- that must hold on the failure
  # path too, or a signed-in submitter's re-rendered form would show an
  # attacker-controlled address back at them.
  test "echoes the signed-in submitter's own email, not the posted one, after a validation failure" do
    user = users(:regular_user)
    sign_in_as(user, stub_auth: true)

    post contact_messages_path,
      params: {contact_message: {email: "attacker@example.org", message: ""}},
      as: :turbo_stream

    assert_response :unprocessable_entity
    assert_match(/value="#{Regexp.escape(user.email)}"/, response.body)
    assert_no_match(/attacker@example\.org/, response.body)
  end

  # visitor_ip is the real visitor IP (not the Cloudflare edge IP), so a shared
  # office or university NAT can burn the 5/hour anonymous bucket collectively
  # -- losing a message here is not a rare edge case.
  test "echoes the submitted message back after being rate limited" do
    5.times do |i|
      post contact_messages_path,
        params: {contact_message: {email: "reader@example.org", message: "Message #{i}"}},
        as: :turbo_stream
      assert_response :success
    end

    post contact_messages_path,
      params: {contact_message: {email: "reader@example.org", message: "The sixth message, rate limited."}},
      as: :turbo_stream

    assert_response :too_many_requests
    assert_match(/The sixth message, rate limited\./, response.body)
  end

  # curl -d "contact_message=x" sends contact_message as a scalar String, not a
  # hash -- params.fetch(:contact_message, {}).permit(...) then called permit
  # on a String and 500'd. This is a public, unauthenticated endpoint.
  test "answers a malformed contact_message param with an ordinary validation failure, not a 500" do
    assert_no_difference "ContactMessage.count" do
      post contact_messages_path, params: {contact_message: "not-a-hash"}, as: :turbo_stream
    end

    assert_response :unprocessable_entity
    assert_equal "text/vnd.turbo-stream.html", response.media_type
  end

  # A filled honeypot persists nothing but still looks like success: a 200 stops
  # a bot retrying, where a 422 brings it back.
  test "silently discards a submission with the honeypot filled" do
    assert_no_difference "ContactMessage.count" do
      post contact_messages_path,
        params: valid_params.merge(website: "http://spam.example"),
        as: :turbo_stream
    end

    assert_response :success
    assert_match(/contact_modal_body/, response.body)
  end

  test "sends no email when the honeypot is filled" do
    AdminMailer.expects(:contact_message).never

    post contact_messages_path,
      params: valid_params.merge(website: "http://spam.example"),
      as: :turbo_stream
  end

  test "rate limits an anonymous submitter after five in an hour" do
    5.times do |i|
      post contact_messages_path,
        params: {contact_message: {email: "reader@example.org", message: "Message #{i}"}},
        as: :turbo_stream
      assert_response :success
    end

    assert_no_difference "ContactMessage.count" do
      post contact_messages_path, params: valid_params, as: :turbo_stream
    end

    assert_response :too_many_requests
    assert_equal "text/vnd.turbo-stream.html", response.media_type
  end

  test "gives a signed-in submitter a larger allowance than an anonymous one" do
    sign_in_as(users(:regular_user), stub_auth: true)

    6.times do |i|
      post contact_messages_path,
        params: {contact_message: {email: "reader@example.org", message: "Message #{i}"}},
        as: :turbo_stream
      assert_response :success
    end
  end

  test "is never cached" do
    post contact_messages_path, params: valid_params, as: :turbo_stream

    assert_match(/no-store/, response.headers["Cache-Control"])
  end
end
