namespace :e2e do
  def playwright_email
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
    email
  end

  desc "Grant the Playwright admin account (e2e/.env PLAYWRIGHT_ADMIN_EMAIL) the global admin role"
  task admin: :environment do
    email = playwright_email
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

  desc "Ensure the Playwright account owns one public and one private books list, each with items"
  task books_public_list: :environment do
    email = playwright_email
    user = User.find_by(email: email)
    abort "No User with email #{email}. Run `bin/rails e2e:admin` first." if user.nil?

    books = Books::Book.where(book_kind: :standalone).limit(3).to_a
    abort "No standalone books in this database." if books.empty?

    public_list = Books::UserList.find_or_create_by!(user: user, name: "E2E Public Books") do |list|
      list.list_type = :custom
    end
    public_list.update!(public: true)
    books.each { |book| public_list.user_list_items.find_or_create_by!(listable: book) }

    private_list = Books::UserList.find_or_create_by!(user: user, name: "E2E Private Books") do |list|
      list.list_type = :custom
    end
    private_list.update!(public: false)
    books.first(1).each { |book| private_list.user_list_items.find_or_create_by!(listable: book) }

    puts "PLAYWRIGHT_PUBLIC_BOOKS_LIST_ID=#{public_list.id}"
    puts "PLAYWRIGHT_PRIVATE_BOOKS_LIST_ID=#{private_list.id}"
  end
end
