# frozen_string_literal: true

namespace :open_library do
  desc "Export every Books::Book as JSONL for the Open Library evaluation pool"
  task :export_books, [:path] => :environment do |_task, args|
    path = args[:path] || Rails.root.join("tmp", "books_for_open_library.jsonl").to_s

    count = File.open(path, "w") do |file|
      Books::OpenLibrary::EvalExport.call(io: file)
    end

    puts "wrote #{count} books to #{path}"

    # Say what was left out rather than letting the number quietly shrink:
    # EvalExport drops the Playwright leftovers, and a silent drop is how a
    # filter that starts matching real books goes unnoticed.
    skipped = Books::Book.count - count
    puts "skipped #{skipped} E2E leftover books" if skipped.positive?
  end
end
