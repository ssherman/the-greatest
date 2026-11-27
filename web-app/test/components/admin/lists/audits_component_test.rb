# frozen_string_literal: true

require "test_helper"

class Admin::Lists::AuditsComponentTest < ViewComponent::TestCase
  setup do
    @list = lists(:books_list)
    @audit = ListAudit.find_by!(list: @list)
  end

  test "renders a verified audit's source link and changed field" do
    @audit.update!(
      note: "Checked against the publisher.", sources: ["https://example.com/source"],
      field_changes: {
        "fields" => {"year_published" => {"from" => 1990, "to" => 1991}},
        "penalties_attached" => [{"id" => 1, "name" => "Western bias"}],
        "penalties_detached" => []
      }
    )

    render_inline(Admin::Lists::AuditsComponent.new(list: @list, can_release: false))

    link = page.find("a[href='https://example.com/source']")
    assert_equal "noopener nofollow", link[:rel]
    assert_equal "_blank", link[:target]
    assert_includes page.text, "year_published"
    assert_includes page.text, "Western bias"
    assert_includes page.text, "Checked against the publisher."
  end

  test "renders row changes and pending requests" do
    @audit.update!(field_changes: {
      "fields" => {}, "penalties_attached" => [], "penalties_detached" => [],
      "items_added" => [{"id" => 90101, "book_id" => 90201, "position" => 1}],
      "items_removed" => [{"id" => 90102, "book_id" => 90202, "position" => 2}],
      "items_changed" => [{"id" => 90103, "position" => {"from" => 3, "to" => 4}}],
      "pending_submissions" => [90301]
    })

    render_inline(Admin::Lists::AuditsComponent.new(list: @list, can_release: false))

    %w[90101 90102 90103 90301].each { |id| assert_includes page.text, id }
  end

  test "an audit written before row changes existed still renders" do
    @audit.update!(field_changes: {"fields" => {"name" => {"from" => "A", "to" => "B"}}, "penalties_attached" => [], "penalties_detached" => []})
    render_inline(Admin::Lists::AuditsComponent.new(list: @list, can_release: false))
    assert_includes page.text, "name"
  end

  test "an open audit shows a Release button only when permitted" do
    @audit.update!(status: :in_progress, verdict: nil, finished_at: nil, lease_expires_at: 1.hour.from_now)

    render_inline(Admin::Lists::AuditsComponent.new(list: @list, can_release: true))
    assert_selector "form[action$='/release'] button"

    render_inline(Admin::Lists::AuditsComponent.new(list: @list, can_release: false))
    assert_no_selector "form[action$='/release']"
  end

  test "renders an in-progress and a released audit without field changes" do
    @audit.update!(status: :in_progress, verdict: nil, finished_at: nil, field_changes: nil, lease_expires_at: 1.hour.from_now)
    render_inline(Admin::Lists::AuditsComponent.new(list: @list, can_release: true))
    assert_selector "[data-testid=audit]"

    @audit.update!(status: :released, finished_at: Time.current)
    render_inline(Admin::Lists::AuditsComponent.new(list: @list, can_release: true))
    assert_selector "[data-testid=audit]"
  end

  test "a list with no audits says so" do
    @audit.destroy!
    render_inline(Admin::Lists::AuditsComponent.new(list: @list, can_release: false))
    assert_selector "[data-testid=no-audits]"
  end
end
