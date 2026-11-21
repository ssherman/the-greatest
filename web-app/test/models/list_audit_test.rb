require "test_helper"

# == Schema Information
#
# Table name: list_audits
#
#  id               :bigint           not null, primary key
#  after            :jsonb
#  before           :jsonb
#  field_changes    :jsonb
#  finished_at      :datetime
#  lease_expires_at :datetime
#  note             :text
#  sources          :jsonb            not null
#  started_at       :datetime
#  status           :integer          default("in_progress"), not null
#  verdict          :integer
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  list_id          :bigint           not null
#  user_id          :bigint
#
# Indexes
#
#  index_list_audits_on_list_id                 (list_id)
#  index_list_audits_on_status_and_finished_at  (status,finished_at)
#  index_list_audits_on_user_id                 (user_id)
#  index_list_audits_one_open_per_list          (list_id) UNIQUE WHERE (status = 0)
#
# Foreign Keys
#
#  fk_rails_...  (list_id => lists.id)
#  fk_rails_...  (user_id => users.id) ON DELETE => nullify
#
class ListAuditTest < ActiveSupport::TestCase
  setup do
    @list = lists(:books_list)
    @user = users(:admin_user)
  end

  def start_audit(list = @list, lease: 1.hour)
    ListAudit.create!(list: list, user: @user, status: :in_progress,
      started_at: Time.current, lease_expires_at: lease.from_now)
  end

  test "database refuses a second in-progress audit on one list" do
    start_audit
    assert_raises(ActiveRecord::RecordNotUnique) { start_audit }
  end

  test "a second audit is allowed once the first is released" do
    first = start_audit
    first.update!(status: :released)
    assert_nothing_raised { start_audit }
  end

  test "open and expired split on lease_expires_at" do
    audit = start_audit(lease: 1.hour)
    assert_includes ListAudit.open, audit
    assert_not_includes ListAudit.expired, audit
    assert_not audit.expired?

    travel 2.hours do
      assert_includes ListAudit.expired, audit
      assert_not_includes ListAudit.open, audit
      assert audit.reload.expired?
    end
  end

  test "done returns finished audits" do
    assert_includes ListAudit.done, list_audits(:books_verified_audit)
  end
end
