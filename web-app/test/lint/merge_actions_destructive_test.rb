# frozen_string_literal: true

require "test_helper"

# Guardrail for `Actions::Admin::BaseAction.destructive?`.
#
# `destructive?` defaults to `false` on the base class. Every controller's
# `execute_action` calls `authorize @record, :destroy? if action_class.destructive?`
# -- the ONLY place a `Merge*` action's permission gate is enforced. An action class
# that forgets to override `destructive?` to `true` leaves that gate silently inert:
# no test fails on its own (a merge still "works"), no lint fires, and the only
# symptom is a domain editor being able to delete a record by merging it away.
#
# This test discovers every `Merge*` action class from the filesystem under
# app/lib/actions/admin/**, so a future `MergeBook` or `MergeAuthor` (increments 2
# and 3) is covered automatically -- nobody has to remember to add it here.
class MergeActionsDestructiveTest < ActiveSupport::TestCase
  test "every Merge* admin action declares itself destructive" do
    assert merge_action_classes.any?, "expected to find at least one Merge* action class " \
      "under app/lib/actions/admin/** -- did the glob or the naming convention change?"

    not_destructive = merge_action_classes.reject(&:destructive?)

    # `.to_s`, not `.name`, in the message below -- every action class here overrides
    # the class method `self.name` for display purposes (e.g. "Merge Another Game
    # Into This One"), which shadows Module#name but not Module#to_s.
    assert_empty not_destructive,
      "These Merge* action classes do not override destructive? to return true, so " \
      "execute_action's `authorize @record, :destroy? if action_class.destructive?` gate " \
      "never runs for them -- a domain editor (write, not delete, permission) could delete " \
      "a record through this action:\n" \
      "#{not_destructive.map { |klass| "  #{klass}" }.join("\n")}\n" \
      "Fix: add `def self.destructive?; true; end` to the action class."
  end

  private

  # Every Merge* class under app/lib/actions/admin/**, found by filesystem glob and
  # loaded by turning its path into a constant -- not by grepping class names, so a
  # class whose file is misnamed relative to its constant would surface as a
  # NameError here rather than silently being skipped.
  def merge_action_classes
    Dir.glob(Rails.root.join("app/lib/actions/admin/**/merge_*.rb")).map do |path|
      relative = Pathname.new(path)
        .relative_path_from(Rails.root.join("app/lib"))
        .to_s
        .delete_suffix(".rb")

      relative.camelize.constantize
    end
  end
end
