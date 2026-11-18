# frozen_string_literal: true

namespace :books do
  namespace :publisher_intake do
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
