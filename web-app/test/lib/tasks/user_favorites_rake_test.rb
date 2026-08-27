# frozen_string_literal: true

require "test_helper"
require "rake"

class UserFavoritesRakeTaskTest < ActiveSupport::TestCase
  setup do
    # Deliberately not `Rails.application.load_tasks`: that walks every
    # railtie's rake_tasks hook, and cssbundling-rails registers its
    # `lib/tasks/cssbundling/build.rake` through both its own hook and Rails'
    # generic per-engine `lib/tasks/**/*.rake` glob, so calling it a second
    # time in an already-booted process re-`load`s that file and Ruby warns
    # "already initialized constant Cssbundling::Tasks::LOCK_FILES" -- a new,
    # unrelated warning line in `bin/rails test`. Loading only the one file
    # this test needs avoids that entirely.
    unless Rake::Task.task_defined?("user_favorites_lists:adopt_legacy_books_list")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      load Rails.root.join("lib/tasks/lists/user_favorites.rake").to_s
    end
    Rake::Task["user_favorites_lists:adopt_legacy_books_list"].reenable
  end

  test "adopt_legacy_books_list is safe to run twice: the adopted list survives its own new name" do
    keep = ::Books::List.create!(
      type: "Books::List",
      name: "Our Users' Top 100 Favorite Books of All Time",
      status: :active
    )
    keep.list_items.create!(listable: books_books(:war_and_peace), position: 1)
    RankedList.create!(
      list: keep,
      ranking_configuration: ranking_configurations(:books_global),
      weight: 40
    )

    # capture_io: the task narrates every step on stdout, and `bin/rails test`
    # is expected to run clean -- an unswallowed puts here is a dozen new lines
    # of noise in the suite output.
    capture_io do
      Rake::Task["user_favorites_lists:adopt_legacy_books_list"].invoke
      Rake::Task["user_favorites_lists:adopt_legacy_books_list"].reenable

      # Second invocation: `keep`'s lookup-by-legacy-name can no longer resolve,
      # since the first run already renamed it. The bug this guards against is
      # the doomed-list query matching the adopted list under its new name --
      # which is exactly ::Books::UserList.generated_list_name.
      Rake::Task["user_favorites_lists:adopt_legacy_books_list"].invoke
    end

    keep.reload
    assert_equal ::Books::UserList.generated_list_name, keep.name
    assert keep.generated_user_favorites?
    assert_equal 1, keep.list_items.count
    assert_equal 1, keep.ranked_lists.count
  end

  test "adopt_legacy_books_list never deletes a list with auto_generated_kind set, regardless of name" do
    # Deliberately EMPTY. A generated list that holds items is protected twice
    # over: by the doomed query's auto_generated_kind filter (the thing under
    # test) and, incidentally, by the ListItem destroy guard raising from inside
    # the cascade. With an item present, deleting the filter still leaves the
    # list standing and this test still passes -- against the exact regression
    # it exists to catch. Empty, the filter is the only thing protecting it.
    keep = ::Books::List.create!(
      type: "Books::List",
      name: ::Books::UserList.generated_list_name,
      status: :active,
      auto_generated_kind: :user_favorites
    )

    capture_io do
      Rake::Task["user_favorites_lists:adopt_legacy_books_list"].invoke
    end

    assert ::Books::List.exists?(keep.id)
  end

  test "adopt_legacy_books_list deletes a genuinely retired list carrying one of the doomed names" do
    doomed = ::Books::List.create!(
      type: "Books::List",
      name: "Our Users' Honorable Mention Favorite Books of All Time",
      status: :active
    )
    doomed.list_items.create!(listable: books_books(:crime_and_punishment), position: 1)

    capture_io do
      Rake::Task["user_favorites_lists:adopt_legacy_books_list"].invoke
    end

    assert_not ::Books::List.exists?(doomed.id)
  end
end
