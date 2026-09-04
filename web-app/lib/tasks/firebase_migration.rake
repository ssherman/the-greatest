require "json"
require "base64"

namespace :firebase do
  desc "Export the v1 Devise cohort as a Firebase auth:import file. Usage: rake 'firebase:export_v1_passwords[/abs/path/users.json]'"
  task :export_v1_passwords, [:path] => :environment do |_t, args|
    path = args[:path]
    abort "Usage: rake 'firebase:export_v1_passwords[/abs/path/users.json]'" if path.blank?

    result = begin
      Services::BooksMigration::FirebasePasswordExport.call(output_path: path)
    rescue Services::BooksMigration::FirebasePasswordExport::UnsafeOutputPath => e
      # Aborting rather than letting this propagate: an operator who typed a
      # path inside the repo needs the sentence, not a backtrace.
      abort e.message
    end

    pp result

    if result[:success]
      puts
      puts "Next, from anywhere OUTSIDE this repository:"
      puts "  npx firebase-tools auth:import #{path} --hash-algo=BCRYPT --project the-greatest-books"
      puts
      puts "Then, once sign-in is confirmed:"
      puts "  rake firebase:backfill_v1_uids"
    else
      abort "Export failed: #{result[:error]}"
    end
  end

  desc "Write a single-record canary import file with a password you choose. Usage: rake 'firebase:canary[/abs/path/canary.json,you+v1@gmail.com,somepassword]'"
  task :canary, [:path, :email, :password] => :environment do |_t, args|
    require "bcrypt"
    path = args[:path]
    email = args[:email]
    password = args[:password]
    abort "Usage: rake 'firebase:canary[/abs/path/canary.json,email,password]'" if [path, email, password].any?(&:blank?)

    # Same repository guard the bulk export uses. This writes a real bcrypt
    # hash, so it gets the same refusal rather than its own weaker rule.
    begin
      Services::BooksMigration::FirebasePasswordExport.assert_safe_output_path!(path)
    rescue Services::BooksMigration::FirebasePasswordExport::UnsafeOutputPath => e
      abort e.message
    end

    # Cost 10 and the $2a$ variant: byte-for-byte the same construction Devise
    # used in 2014. A hash's age changes nothing about how bcrypt verifies it,
    # which is why this proves the import path for all 30,463 real hashes.
    hash = BCrypt::Password.create(password, cost: 10).to_s
    unless Services::BooksMigration::FirebasePasswordExport::BCRYPT_GRAMMAR.match?(hash)
      abort "Generated hash does not match the cohort grammar: #{hash[0, 7]}..."
    end

    record = {
      "localId" => "tgbv1-canary",
      "email" => email.strip.downcase,
      "emailVerified" => false,
      "passwordHash" => Base64.urlsafe_encode64(hash, padding: false),
      "createdAt" => (Time.current.to_i * 1000).to_s
    }

    File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
      f.write(JSON.pretty_generate({"users" => [record]}))
    end

    puts "Wrote #{path}"
    puts "  npx firebase-tools auth:import #{path} --hash-algo=BCRYPT --project the-greatest-books"
    puts "Then sign in at https://dev-new.thegreatestbooks.org with #{email} and the password you passed."
    puts "If that fails, FirebasePasswordExport#encode_hash is the one thing to change."
    puts
    puts "Run the import TWICE and sign in again after the second. The whole re-run story"
    puts "rests on Firebase replacing a colliding localId rather than duplicating it."
  end
end
