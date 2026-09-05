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

    pp result.to_h

    if result.success?
      puts
      puts "Next, from anywhere OUTSIDE this repository:"
      puts "  npx firebase-tools auth:import #{path} --hash-algo=BCRYPT --project the-greatest-books"
      puts
      puts "Then, once sign-in is confirmed:"
      puts "  rake firebase:backfill_v1_uids"
    else
      abort "Export failed: #{result.errors.join(", ")}"
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
      # The creation mode is ignored when the path already exists, so a
      # re-run over a previous 0644 file would leave the hash readable.
      f.chmod(0o600)
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

  desc "Rehearse the uid-link path for one user. Usage: rake 'firebase:canary_for_user[/abs/path/c.json,<users.id>,somepassword]'"
  task :canary_for_user, [:path, :user_id, :password] => :environment do |_t, args|
    require "bcrypt"
    path = args[:path]
    user_id = args[:user_id]
    password = args[:password]
    if [path, user_id, password].any?(&:blank?)
      abort "Usage: rake 'firebase:canary_for_user[/abs/path/c.json,<users.id>,somepassword]'"
    end

    export = Services::BooksMigration::FirebasePasswordExport
    begin
      export.assert_safe_output_path!(path)
    rescue export::UnsafeOutputPath => e
      abort e.message
    end

    user = User.find_by(id: user_id)
    abort "No users row with id=#{user_id}. Pick a synthetic row you created for this." if user.nil?
    abort "users##{user.id} has no email; sign-in would have nothing to match." if user.email.blank?

    uid = export.uid_for(user.id)

    # Replace is total. Pointing this at a real cohort member would overwrite
    # the Firebase account they are about to be migrated into, substituting a
    # password chosen here for the one they have used since 2014.
    #
    # Asked of the LEGACY table, not of exportable_ids. exportable_ids drops
    # every row that already holds an auth_uid, so after a backfill pass it
    # reports a migrated cohort member as not-in-cohort -- and the different-uid
    # check below cannot catch them either, because their uid is exactly the
    # derived one. Both guards passed for a real user (users#2) once its
    # auth_uid was seeded, which is to say the protection disappeared at the
    # moment their Firebase account started existing.
    if export.legacy_cohort_member?(user.id)
      abort "users##{user.id} is a v1 cohort member. Importing this file would replace their " \
            "real migrated account with a password chosen here. Use a synthetic row instead."
    end

    # Same clobber FirebaseUidBackfill guards against: overwriting a
    # Firebase-native uid detaches the person from the account they sign in with.
    if user.auth_uid.present? && user.auth_uid != uid
      abort "users##{user.id} already holds auth_uid=#{user.auth_uid.inspect}. Refusing to overwrite it."
    end

    # The setup that makes this a rehearsal rather than a repeat of the plain
    # canary: with auth_uid pre-seeded, step 1 of UserAuthenticationService
    # #find_user matches by uid and the user lands on THIS row. The ordinary
    # backfill will not do it for us -- its cohort is the export set, which by
    # the check above excludes this id.
    user.update_columns(auth_uid: uid, updated_at: Time.current) if user.auth_uid.blank?

    hash = BCrypt::Password.create(password, cost: 10).to_s
    abort "Generated hash does not match the cohort grammar: #{hash[0, 7]}..." unless export::BCRYPT_GRAMMAR.match?(hash)

    record = {
      "localId" => uid,
      "email" => user.email.strip.downcase,
      "emailVerified" => false,
      "passwordHash" => Base64.urlsafe_encode64(hash, padding: false),
      "createdAt" => ((user.created_at || Time.current).to_i * 1000).to_s
    }

    File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
      f.chmod(0o600)
      f.write(JSON.pretty_generate({"users" => [record]}))
    end

    puts "Wrote #{path}"
    puts "  users##{user.id}  email=#{user.email}  auth_uid=#{uid}"
    puts
    puts "  npx firebase-tools auth:import #{path} --hash-algo=BCRYPT --project the-greatest-books"
    puts
    puts "Then sign in as #{user.email} with the password you passed, and assert:"
    puts "  * you land on users##{user.id} -- NOT a newly created row"
    puts "  * User.where(email: #{user.email.inspect}).count is still 1"
    puts "  * that row's lists/data are intact"
    puts
    puts "That is the path all #{export.exportable_ids.size} migrated users take. The plain"
    puts "firebase:canary cannot test it: tgbv1-canary matches no row, so it only ever"
    puts "exercises account creation."
  end

  desc "Write tgbv1-<id> into users.auth_uid for the v1 cohort. Pass DRY_RUN=1 to preview."
  task backfill_v1_uids: :environment do
    dry = ENV["DRY_RUN"].present?
    puts dry ? "DRY RUN -- nothing will be written" : "Writing auth_uid for the v1 cohort..."

    result = Services::BooksMigration::FirebaseUidBackfill.call(dry_run: dry)
    pp result.to_h

    abort "Backfill failed: #{result.errors.join(", ")}" unless result.success?
  end
end
