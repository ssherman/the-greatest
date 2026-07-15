namespace :e2e do
  desc "Grant the Playwright admin account (e2e/.env PLAYWRIGHT_ADMIN_EMAIL) the global admin role"
  task admin: :environment do
    env_file = Rails.root.join("e2e", ".env")
    abort "Missing #{env_file}. Copy e2e/.env.example and fill it in." unless File.exist?(env_file)

    email = File.readlines(env_file)
      .grep(/\APLAYWRIGHT_ADMIN_EMAIL=/)
      .first
      &.split("=", 2)
      &.last
      &.strip
      &.delete_prefix('"')
      &.delete_suffix('"')

    abort "PLAYWRIGHT_ADMIN_EMAIL not set in #{env_file}" if email.blank?

    user = User.find_by(email: email)

    if user.nil?
      abort <<~MSG
        No User with email #{email}.

        The account must exist in Firebase AND in this database. Sign in once through
        the browser as that account to create the Rails User record, then re-run this task.
      MSG
    end

    user.update!(role: :admin)
    puts "#{email} (id #{user.id}) is now a global admin."
  end
end
