# frozen_string_literal: true

namespace :books do
  namespace :publisher_intake do
    desc "Start a manual discovery run for a source: books:publisher_intake:run[source]"
    task :run, [:source] => :environment do |_task, args|
      strategy = Books::PublisherIntake::Sources.fetch(args[:source])
      abort "unknown source #{args[:source].inspect}; registered: #{Books::PublisherIntake::Sources.registry.keys.join(", ")}" if strategy.nil?

      run = Services::Books::PublisherIntake::StartRun.call(source: strategy, kind: :manual).data[:run]
      puts "started run #{run.id} for #{strategy.key}: #{run.counts["requests"]} requests, status #{run.status}"
    end

    desc "Move up to limit baseline listings to pending, highest key first: books:publisher_intake:release_baseline[source,limit]"
    task :release_baseline, [:source, :limit] => :environment do |_task, args|
      abort "usage: books:publisher_intake:release_baseline[source,limit]" unless args[:source].present? && args[:limit].to_i.positive?

      released = Services::Books::PublisherIntake::ReleaseBaseline.call(source: args[:source], limit: args[:limit]).data[:released]
      puts "released #{released} listings of #{args[:source]} to pending"
    end

    desc "Re-read stored pages with the current parser, fetching nothing: books:publisher_intake:reparse[source]"
    task :reparse, [:source] => :environment do |_task, args|
      strategy = Books::PublisherIntake::Sources.fetch(args[:source])
      abort "unknown source #{args[:source].inspect}; registered: #{Books::PublisherIntake::Sources.registry.keys.join(", ")}" if strategy.nil?

      changed = unchanged = 0
      Books::PublisherListing.where(source: strategy.key).where("parser_version IS NULL OR parser_version < ?", strategy.parser_version)
        .joins(:html_attachment).find_each do |listing|
        if Services::Books::PublisherIntake::Reparse.call(listing: listing).data[:changed]
          changed += 1
        else
          unchanged += 1
        end
      end
      puts "reparsed #{strategy.key}: #{changed} changed, #{unchanged} not changed"
    end

    desc "Development only: run discovery then read listings synchronously: books:publisher_intake:rehearse[source,limit,max_discovery_requests]"
    task :rehearse, [:source, :limit, :max_discovery_requests] => :environment do |_task, args|
      abort "books:publisher_intake:rehearse does not run in production" if Rails.env.production?
      strategy = Books::PublisherIntake::Sources.fetch(args[:source])
      abort "unknown source #{args[:source].inspect}; registered: #{Books::PublisherIntake::Sources.registry.keys.join(", ")}" if strategy.nil?
      abort "usage: books:publisher_intake:rehearse[source,limit,max_discovery_requests]" unless args[:limit].to_i.positive?

      result = Services::Books::PublisherIntake::Rehearse.call(source: strategy, limit: args[:limit].to_i,
        max_discovery_requests: args[:max_discovery_requests].presence)
      abort result.errors.join(", ") unless result.success?
    end

    desc "Report publisher intake per source"
    task status: :environment do
      Services::Books::PublisherIntake::Status.call.data[:sources].each do |s|
        puts "#{s[:key]} (#{s[:name]})#{" [not registered]" unless s[:registered]}: #{s[:enabled] ? "enabled" : "not enabled"}"
        run = s[:last_run]
        puts "  last run: #{run ? "##{run[:id]} #{run[:kind]} #{run[:status]} started #{run[:started_at]}" : "none"}"
        puts "  listings: #{s[:listings].empty? ? "none" : s[:listings].map { |k, v| "#{k} #{v}" }.join(", ")}"
        held = s[:titles][:held]
        puts "  titles: ready #{s[:titles][:ready]}, held #{held.values.sum}#{" (#{held.map { |k, v| "#{k} #{v}" }.join(", ")})" if held.any?}"
        puts "  fetches today: #{s[:fetches_today]} of #{s[:daily_cap]}#{", blocked until #{s[:blocked_until]}" if s[:blocked_until]}"
      end
    end

    desc "Development only: fetch a page and save it, trimmed and gzipped, as a test fixture: books:publisher_intake:capture[source,url,name]"
    task :capture, [:source, :url, :name] => :environment do |_task, args|
      abort "books:publisher_intake:capture runs in development only" unless Rails.env.development?
      abort "usage: books:publisher_intake:capture[source,url,name]" unless args.to_h.values_at(:source, :url, :name).all?(&:present?)
      abort "source and name may hold letters, digits, _ and - only" unless [args[:source], args[:name]].all? { |value| value.match?(/\A[\w-]+\z/) }

      page = Books::PublisherIntake.client.fetch(args[:url], wait_for_selector: "h1")
      puts "status #{page.status}, title #{page.title.inspect}"
      html = Books::PublisherIntake::FixtureTrimmer.call(page.html)
      path = Rails.root.join("test/fixtures/files/publisher_intake", args[:source], "#{args[:name]}.html.gz")
      FileUtils.mkdir_p(path.dirname)
      Zlib::GzipWriter.open(path) { |gz| gz.write(html) }
      puts "wrote #{path} (#{html.bytesize} bytes unzipped)"
    end
  end
end
