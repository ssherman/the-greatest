# frozen_string_literal: true

require "test_helper"

# Guardrail against daisyUI v4 classes creeping back into the app.
#
# This app runs daisyUI 5.7.x. The classes in REMOVED_CLASSES existed in
# daisyUI 4 and were removed in 5 -- they are simply absent from the compiled
# CSS, so using one is a SILENT failure: no build error, no runtime error, no
# visual difference until someone notices a control that looks subtly wrong
# (or, in the case of "select" on a <select multiple>, badly wrong). Because
# ~90 files already contain these classes, "follow the existing pattern in
# this file/a neighbouring file" reliably reproduces the bug -- see CLAUDE.md.
#
# REMOVED_CLASSES: the list. Extend it if a future daisyUI upgrade removes
# more classes app code still relies on.
#
# ALLOWLIST: a literal, generated-once list of files that already contained a
# removed class at the time this guardrail was added. Sweeping all of them to
# daisyUI 5 markup is separate work and deliberately not bundled into whatever
# change added this test. It is a plain array of paths -- not a glob, not a
# directory prefix -- so every grandfathered file is visible here and can be
# deleted as it gets cleaned up. The test enforces both directions:
#   - a NEW file, or a NEW occurrence in a file not on this list, fails the
#     "no removed classes outside the allowlist" assertion below
#   - an allowlisted file that has been fully cleaned up (no more removed
#     classes anywhere in it) fails the "allowlist has no stale entries"
#     assertion -- that failure message tells you which line to delete here
# That second check is what keeps this list shrinking instead of becoming a
# permanent exemption. When you clean up a file, delete its entry.
class DaisyuiV4ClassesTest < ActiveSupport::TestCase
  REMOVED_CLASSES = %w[
    form-control
    label-text
    label-text-alt
    input-bordered
    select-bordered
    textarea-bordered
    file-input-bordered
    input-disabled
    table-hover
    tabs-boxed
  ].freeze

  ALLOWLIST = %w[].freeze

  test "no removed daisyUI v4 classes outside the grandfathered allowlist" do
    unexpected = offenders.keys - ALLOWLIST

    assert_empty unexpected,
      "Found daisyUI v4 class(es) removed in v5 (#{REMOVED_CLASSES.join(", ")}) in " \
      "file(s) not on the ALLOWLIST in #{__FILE__}:\n" \
      "#{unexpected.map { |f| "  #{f}: #{offenders[f].join(", ")}" }.join("\n")}\n" \
      "See CLAUDE.md's daisyUI v5 section and docs/external-libraries/daisyui-llms.txt " \
      "for the current markup (fieldset/fieldset-legend, label, bare input/select/checkbox)."
  end

  test "allowlist has no stale entries" do
    stale = ALLOWLIST - offenders.keys

    assert_empty stale,
      "These ALLOWLIST entries in #{__FILE__} no longer contain any removed daisyUI v4 " \
      "class -- the file(s) were cleaned up. Delete the entry so the allowlist keeps " \
      "shrinking:\n#{stale.map { |f| "  #{f}" }.join("\n")}"
  end

  private

  # Path (relative to Rails.root) => array of removed classes found, for
  # every file under app/views/** and app/components/** that uses one.
  #
  # Only scans text inside a `class="..."` / `class: "..."` / `className = "..."`
  # value -- ERB/Ruby comments are stripped first -- and only counts a whole
  # space-separated class token as a hit, never a substring.
  #
  # Whole-token matching matters because "file-input-bordered" contains
  # "input-bordered". Both are dead, and both are listed above; token matching
  # is what makes a file containing the former get reported as that class
  # alone rather than as two overlapping hits. Note that plain "file-input"
  # IS a current daisyUI 5 class and must never be added to the list.
  def offenders
    @offenders ||= scan_target_files
  end

  def scan_target_files
    target_files.each_with_object({}) do |relative_path, result|
      classes = removed_classes_in(strip_comments(File.read(Rails.root.join(relative_path))))
      result[relative_path] = classes if classes.any?
    end
  end

  def target_files
    Dir.glob(Rails.root.join("{app/views,app/components,app/javascript}/**/*"))
      .select { |path| File.file?(path) }
      .map { |path| Pathname.new(path).relative_path_from(Rails.root).to_s }
      .sort
  end

  def strip_comments(content)
    content
      .gsub(/<%#.*?%>/m, "") # ERB comments, e.g. <%# ... %>
      .gsub(/^\s*#.*$/, "") # full-line Ruby comments, e.g. in .rb component files
  end

  def removed_classes_in(content)
    found = []
    content.scan(/\bclass(?:Name)?\s*[:=]\s*(["'`])(.*?)\1/m) do |_quote, value|
      value.split(/\s+/).each do |token|
        found << token if REMOVED_CLASSES.include?(token)
      end
    end
    # classList.add("a", "b") / .remove(...) / .toggle("x", cond) / .replace(...)
    content.scan(/classList\.(?:add|remove|toggle|replace)\(([^)]*)\)/m) do |args|
      args[0].scan(/["'`]([^"'`]*)["'`]/) do |literal|
        literal[0].split(/\s+/).each do |token|
          found << token if REMOVED_CLASSES.include?(token)
        end
      end
    end
    found.uniq
  end
end
