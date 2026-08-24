# frozen_string_literal: true

require "test_helper"

# config/asset_bundles.json is the single source of truth for what the
# JavaScript build produces. rollup.config.js reads it to decide what to build;
# Ruby reads it to know what a layout is allowed to ask for.
#
# The reason it is shared rather than duplicated: Propshaft raises
# Propshaft::MissingAssetError on a missing asset, so a layout naming a bundle
# the build does not produce is not a degraded page, it is a 500 on every page
# of that site -- and app/assets/builds/* is gitignored, so no test can catch it
# by inspecting build output. Keeping one list, checked from both sides, is what
# makes that unrepresentable.
#
# Task 5 adds the layout -> bundle direction to this file.
class AssetBundleCoverageTest < ActiveSupport::TestCase
  test "the bundle registry is valid JSON mapping names to entry files" do
    assert_kind_of Hash, registry, "config/asset_bundles.json must be a JSON object"
    refute_empty registry, "config/asset_bundles.json is empty"

    registry.each do |name, entry|
      assert_match(/\A[a-z0-9-]+\z/, name,
        "Bundle name #{name.inspect} must be lowercase kebab-case: it becomes the " \
        "built filename and the argument to javascript_include_tag.")
      assert_kind_of String, entry, "Entry for #{name.inspect} must be a path string"
    end
  end

  test "every registered bundle has an entry file on disk" do
    missing = registry.reject { |_name, entry| File.exist?(Rails.root.join(entry)) }

    assert_empty missing,
      "These bundles are registered in config/asset_bundles.json but their entry " \
      "file does not exist, so the build would fail:\n" \
      "#{missing.map { |name, entry| "  #{name} -> #{entry}" }.join("\n")}"
  end

  test "every domain layout's bundle is produced by the build" do
    missing = domain_layouts.reject { |domain, _path| registry.key?("#{domain}-web") }

    assert_empty missing,
      "These domain layouts resolve to a bundle that config/asset_bundles.json does " \
      "not produce. Propshaft raises MissingAssetError on a missing asset, so this " \
      "is a 500 on every page of that site, not a degraded page:\n" \
      "#{missing.map { |domain, path| "  #{domain} (#{path}) needs bundle #{domain}-web" }.join("\n")}"
  end

  test "the admin layout's bundle is produced by the build" do
    assert registry.key?("admin"),
      "app/views/layouts/admin.html.erb loads the \"admin\" bundle, but " \
      "config/asset_bundles.json does not produce it."
  end

  test "no layout references a bundle outside the registry" do
    offenders = layout_files.each_with_object({}) do |relative_path, result|
      names = File.read(Rails.root.join(relative_path))
        .scan(/javascript_include_tag\s+["']([^"']+)["']/)
        .flatten
        .reject { |name| registry.key?(name) }
      result[relative_path] = names if names.any?
    end

    assert_empty offenders,
      "These layouts name a JavaScript bundle the build does not produce:\n" \
      "#{offenders.map { |path, names| "  #{path}: #{names.join(", ")}" }.join("\n")}"
  end

  private

  def registry
    @registry ||= JSON.parse(File.read(Rails.root.join("config/asset_bundles.json")))
  end

  # "books" => "app/views/layouts/books/application.html.erb", for every domain
  # that has its own layout. Derived from disk rather than hardcoded so a new
  # domain layout cannot be added without a matching bundle.
  def domain_layouts
    @domain_layouts ||= Dir.glob(Rails.root.join("app/views/layouts/*/application.html.erb"))
      .to_h { |path|
        relative = Pathname.new(path).relative_path_from(Rails.root).to_s
        [relative.split("/")[3], relative]
      }
  end

  def layout_files
    @layout_files ||= Dir.glob(Rails.root.join("app/views/layouts/**/*.erb"))
      .map { |path| Pathname.new(path).relative_path_from(Rails.root).to_s }
      .sort
  end
end
