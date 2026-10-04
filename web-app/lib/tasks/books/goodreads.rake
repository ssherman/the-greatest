namespace :books do
  namespace :goodreads do
    desc "Dry run: resolve a Goodreads export CSV and print every decision; saves nothing " \
      "(Open Library and matching AI calls are still made). Usage: books:goodreads:resolve_file[path,user_id]"
    task :resolve_file, [:path, :user_id] => :environment do |_task, args|
      path = args[:path]
      abort "usage: books:goodreads:resolve_file[path,user_id]" if path.blank?
      abort "no such file: #{path}" unless File.file?(path)

      user = args[:user_id].present? ? User.find(args[:user_id]) : User.order(:id).first!
      result = Services::Books::GoodreadsImports::DryRun.call(bytes: File.binread(path), user: user)
      abort result.errors.join("; ") unless result.success?

      puts result.data[:report]
    end
  end
end
