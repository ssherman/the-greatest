require "test_helper"

class ListSubmissionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! "dev-new.thegreatestbooks.org"
    @user = users(:regular_user)
    @params = {
      list: {name: "Greatest Books Ever", source: "The Times",
             url: "https://example.com/greatest", description: "A list."},
      list_type: "Books::List"
    }
    # AdminMailer.new_list_submission is built in Task 9. Stubbing it here keeps
    # this task independently testable -- Mocha defines the method on the stub, so
    # these tests pass before the mailer exists and keep passing after.
    AdminMailer.stubs(:new_list_submission).returns(stub(deliver_later: true))

    # The rate limit store is a single MemoryStore instance shared by the whole
    # process (config/initializers/rate_limit_store.rb) -- without clearing it
    # here, whichever test runs after enough anonymous submissions trips the
    # limit instead of the dedicated rate-limit test below. Same fix as
    # CorrectionsControllerTest's and ReviewsControllerTest's setup.
    Rails.application.config.x.rate_limit_store.clear
  end

  test "new renders the form" do
    get "/lists/new"

    assert_response :success
    assert_select "form[action=?]", "/list_submissions"
  end

  # Read the books layout's robots helper and match this assertion to the markup it
  # ACTUALLY emits before running the test -- the selector below is the expected
  # shape, not verified output. Books defaults to noindex unless @indexable is
  # truthy, so this passes on books either way; the assertion exists to pin it.
  test "new is not indexable" do
    get "/lists/new"

    assert_response :success
    assert_select "meta[name=robots][content*=?]", "noindex"
  end

  test "new does not render a type picker on books" do
    get "/lists/new"

    assert_response :success
    assert_select "input[name=list_type][type=radio]", count: 0
  end

  test "create stores an anonymous submission and redirects to thanks" do
    assert_difference "Books::List.count", 1 do
      post "/list_submissions", params: @params
    end

    assert_redirected_to "/lists/thanks"
    list = Books::List.order(:created_at).last
    assert list.unapproved?
    assert_not_nil list.submitted_at
    assert_nil list.submitted_by
  end

  test "create attributes a signed-in submission" do
    sign_in_as(@user, stub_auth: true)

    post "/list_submissions", params: @params

    assert_redirected_to "/lists/thanks"
    assert_equal @user, Books::List.order(:created_at).last.submitted_by
  end

  test "create stores an anonymous submitter email" do
    post "/list_submissions", params: @params.merge(submitter_email: "reader@example.com")

    assert_equal "reader@example.com", Books::List.order(:created_at).last.submitter_email
  end

  test "a filled honeypot is discarded but still looks like success" do
    assert_no_difference "Books::List.count" do
      post "/list_submissions", params: @params.merge(website: "http://spam.example")
    end

    assert_redirected_to "/lists/thanks"
  end

  test "create re-renders the form with an error when the name is blank" do
    assert_no_difference "Books::List.count" do
      post "/list_submissions", params: @params.deep_merge(list: {name: ""})
    end

    assert_response :unprocessable_entity
  end

  test "create tells the submitter when the url is already known" do
    Books::List.create!(name: "Already here", status: :active,
      url: "https://example.com/greatest")

    assert_no_difference "Books::List.count" do
      post "/list_submissions", params: @params
    end

    assert_response :unprocessable_entity
    assert_match(/already have this list/i, response.body)
  end

  test "create rejects a list type the domain does not accept" do
    post "/list_submissions", params: @params.merge(list_type: "Music::Albums::List")

    assert_response :bad_request
  end

  test "create rejects an unknown list type without constantizing it" do
    post "/list_submissions", params: @params.merge(list_type: "Kernel")

    assert_response :bad_request
  end

  test "thanks renders" do
    get "/lists/thanks"

    assert_response :success
  end

  test "create notifies the owner" do
    AdminMailer.unstub(:new_list_submission)
    AdminMailer.expects(:new_list_submission).once.returns(stub(deliver_later: true))

    post "/list_submissions", params: @params
  end

  test "an anonymous submitter is rate limited" do
    Services::Lists::Submission.stubs(:call).returns(
      Services::Lists::Submission::Result.new(success?: true, data: Books::List.new, errors: [])
    )

    11.times do |i|
      post "/list_submissions", params: @params.deep_merge(list: {url: "https://example.com/#{i}"})
    end

    assert_response :too_many_requests
  end
end
