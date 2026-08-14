# frozen_string_literal: true

require "test_helper"

# Guardrail against daisyUI v4 classes creeping back into the app.
#
# This app runs daisyUI 5.7.x. The classes in REMOVED_CLASSES existed in
# daisyUI 4 and were removed in 5 -- they are simply absent from the compiled
# CSS, so using one is a SILENT failure: no build error, no runtime error, no
# visual difference until someone notices a control that looks subtly wrong
# (or, in the case of "select" on a <select multiple>, badly wrong).
#
# The codebase is CLEAN: a branch-wide sweep removed every occurrence of
# every REMOVED_CLASSES token from app/views, app/components, app/javascript,
# and app/helpers (everywhere target_files below scans), and ALLOWLIST is
# empty. If you trip this guard, the fix is to remove the class from the
# file you just touched -- NOT to add that file to ALLOWLIST. Adding an
# allowlist entry is the one move that would let a removed class back into a
# codebase that was just made free of them; it undoes the point of the
# sweep, it does not sanction it.
#
# REMOVED_CLASSES: the list. Extend it if a future daisyUI upgrade removes
# more classes app code still relies on.
#
# ALLOWLIST: the escape hatch, kept for whenever one is genuinely needed
# again (e.g. a removed class that must temporarily coexist with this guard
# mid-migration on some future change) -- not a place to park today's
# violation. It is empty and is meant to stay empty. It is a plain array of
# paths -- not a glob, not a directory prefix -- so any entry that does get
# added is visible here, not hidden in a pattern. The test enforces both
# directions:
#   - a file with a removed class not on ALLOWLIST fails "no removed classes
#     outside the allowlist" below
#   - an ALLOWLIST entry for a file that no longer contains any removed
#     class fails "allowlist has no stale entries" -- that failure message
#     tells you which line to delete
# With ALLOWLIST empty, the second check has nothing to compare against and
# can never fail right now -- it only starts pulling weight again once an
# entry exists. Until then, THIS COMMENT is the only thing stopping someone
# from reading "there's an allowlist" and treating it as the sanctioned fix.
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

  test "no removed daisyUI v4 classes outside the allowlist" do
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
  # every file under app/views/**, app/components/**, app/javascript/**, and
  # app/helpers/** that uses one.
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
    Dir.glob(Rails.root.join("{app/views,app/components,app/javascript,app/helpers}/**/*"))
      .select { |path| File.file?(path) }
      .map { |path| Pathname.new(path).relative_path_from(Rails.root).to_s }
      .sort
  end

  def strip_comments(content)
    content
      .gsub(/<%#.*?%>/m, "") # ERB comments, e.g. <%# ... %>
      .gsub(/^\s*#.*$/, "") # full-line Ruby comments, e.g. in .rb component files
  end

  # Known limitations (documented, not chased -- these are accepted gaps,
  # not a to-do list; matching them would mean parsing ERB/Ruby/JS, not
  # scanning text):
  #
  # - A dead class hidden inside ERB/Ruby interpolation, e.g.
  #   class="input <%= 'input-bordered' if disabled %>" or
  #   class: "input #{'input-bordered' if y}". The class(?:Name)? regex
  #   below does capture the full attribute value in these cases, but the
  #   quoted literal keeps its own quote characters when the value is
  #   whitespace-split, so the token never equals the bare class name and
  #   the whole-token match misses it. This is the exact shape of the one
  #   occurrence the sweep's codemod could not rewrite automatically
  #   (app/components/autocomplete_component.html.erb) -- this guard
  #   structurally cannot catch the hardest case it just cleaned up.
  # - Variable/dynamic class-name construction generally: `class: ["input",
  #   "input-bordered"]` (array literal), `class: class_names(...)`, and
  #   `setAttribute("class", ...)` are all different syntax shapes than the
  #   `class(?:Name)?\s*[:=]\s*(["'`])` pattern expects immediately after the
  #   colon/equals, so none of them are scanned at all.
  # - `classList.toggle(isValid(x), "input-bordered")`: the classList regex's
  #   `[^)]*` argument capture stops at the first `)`, so a parenthesised
  #   call in an earlier argument hides any string literal that comes after
  #   it. Inert today -- the only non-literal first argument anywhere in the
  #   codebase has no parenthesis (e.g.
  #   `spoiler.classList.add(this.constructor.REVEALED_CLASSES)`) -- but a
  #   future `classList.toggle(someCall(x), "dead-class")` would slip
  #   through silently.
  #
  # Separately: strip_comments above only strips ERB comments and full-line
  # Ruby `#` comments -- it does not strip JS `//` or `/* */`. A
  # commented-out `classList.add("input-bordered")` in a .js file would
  # therefore false-positive. That fails safe (blocks CI on text that looks
  # like a dead class even though it isn't live) and is left as-is on
  # purpose.
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
