require "json"
require "base64"

module Services
  module BooksMigration
    # Exports the v1 Devise cohort as a Firebase Auth bulk-import file, so those
    # users sign in with the password they already have.
    #
    # This replaces the legacy site's bespoke "decrypt the old password, compare
    # it, then create a Firebase account" endpoint, which could be driven by
    # anyone who knew an email address. Importing the hashes means there is no
    # such endpoint to attack: Firebase verifies the password itself, through
    # the ordinary sign-in path.
    #
    # Run it, then:
    #   npx firebase-tools auth:import <path> --hash-algo=BCRYPT --project the-greatest-books
    #
    # Nothing here touches Firebase. No service-account credential belongs in
    # this application for a one-time job.
    class FirebasePasswordExport
      # Every one of the 30,463 real hashes matches this exactly. Anything that
      # does not is skipped rather than shipped -- Firebase would reject the row
      # anyway, and a malformed hash would occupy an address its owner could
      # then never claim.
      BCRYPT_GRAMMAR = %r{\A\$2a\$10\$[./A-Za-z0-9]{53}\z}

      # Deliberately loose: this only rejects addresses Firebase itself will
      # reject. 46 real rows look like "someone@gmail" with no TLD -- signup
      # typos that were never deliverable. They are skipped, NEVER repaired:
      # inferring "gmail.com" from "gmail" would create an account at an address
      # the user does not control.
      EMAIL_GRAMMAR = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/

      UID_PREFIX = "tgbv1-"
      BATCH_SIZE = 1000

      # Stands in for a NULL last_sign_in_at when ranking duplicates. A row that
      # never signed in must lose to one that did, and two such rows must still
      # resolve deterministically -- see rank_for.
      NEVER_SIGNED_IN = Time.at(0).utc.freeze

      class UnsafeOutputPath < StandardError; end

      # The single definition of the uid. FirebaseUidBackfill calls this rather
      # than rebuilding the string, so the exported localId and the value written
      # to users.auth_uid cannot drift apart.
      def self.uid_for(legacy_id)
        "#{UID_PREFIX}#{legacy_id}"
      end

      def self.call(output_path:)
        new(output_path).call
      end

      # The file is tens of thousands of password hashes and this repository is
      # public. Refusing the whole repo tree is cheaper than trusting a
      # .gitignore entry to be correct forever.
      #
      # Public and on the class because the canary rake task writes a hash too.
      # The plan had the canary writing straight to whatever path it was given
      # with no check at all -- one hash rather than 30,463, but the same
      # mistake, and its own example filename (canary.json) matched none of the
      # .gitignore patterns the plan added.
      def self.assert_safe_output_path!(output_path)
        expanded = File.expand_path(output_path)
        repo_root = Rails.root.parent.to_s

        if expanded.start_with?(repo_root + File::SEPARATOR)
          raise UnsafeOutputPath,
            "refusing to write password hashes inside the repository (#{repo_root}). " \
            "Choose a path outside it."
        end

        nil
      end

      def initialize(output_path)
        @output_path = output_path
        @skipped = {invalid_email: 0, invalid_hash: 0, duplicate_email: 0, already_linked: 0}
      end

      def call
        assert_safe_output_path!

        best = {}
        legacy_each do |attrs|
          record = build_record(attrs)
          next if record.nil?

          key = record.fetch("email")
          rank = rank_for(attrs)

          # Zero duplicates exist today. Kept as an assertion: the collision is
          # counted so a non-zero report is investigated rather than silently
          # accepted, and the winner is decided by rank rather than by arrival
          # order -- see rank_for for why arrival order cannot be trusted.
          if best.key?(key)
            @skipped[:duplicate_email] += 1
            next if (best[key][:rank] <=> rank) >= 0
          end

          best[key] = {rank: rank, record: record}
        end

        write(best.values.map { |entry| entry[:record] })

        {success: true, data: {path: @output_path, exported: best.size, skipped: @skipped}}
      rescue UnsafeOutputPath
        raise
      rescue => e
        {success: false, error: e.message, data: {path: @output_path, exported: 0, skipped: @skipped}}
      end

      private

      # Which of two rows sharing an email wins: most recently active first,
      # then highest legacy id.
      #
      # This is deliberately NOT expressed as an ORDER BY on the cohort scope.
      # find_each discards a scoped order -- it forces ORDER BY id and logs
      # "Scoped order is ignored, use :cursor with :order to configure custom
      # order" -- so a rule that relied on arrival order would silently degrade
      # to "highest legacy id wins" against the real database while continuing
      # to pass any test that fed rows in the intended order. Ranking each row
      # explicitly makes the outcome independent of how the batches arrive.
      #
      # The id is the tie-break rather than decoration: with 0 duplicates today
      # this never fires, but if it ever does, two rows that both never signed
      # in must still resolve the same way on every run or the export stops
      # being byte-identical.
      def rank_for(attrs)
        [attrs["last_sign_in_at"]&.to_time || NEVER_SIGNED_IN, attrs["id"].to_i]
      end

      # Cohort ids whose new-table row already carries a Firebase uid.
      #
      # Measured 2026-09-04: 30 of the 30,463. All 30 hold Firebase-NATIVE uids
      # rather than tgbv1- ones, 28 of them acquired on the new app, and they
      # are active -- sign-in counts up to 120, the most recent the day before
      # this was written. The plan assumed this set was empty ("zero sign-ins in
      # two years"); it is not.
      #
      # They must not be exported. Firebase's import API does not check email
      # duplication, so importing them would create a SECOND account per
      # address holding their 2014 password, leaving two identities for one
      # email and making a password reset ambiguous. They already have a
      # working way in. FirebaseUidBackfill skips exactly these rows too --
      # export and write-back have to agree on who is being migrated.
      #
      # Loaded once rather than per row: the cohort is 30k and this is a single
      # indexed scan.
      def already_linked_ids
        @already_linked_ids ||= ::User.where.not(auth_uid: nil).pluck(:id).to_set
      end

      def build_record(attrs)
        if already_linked_ids.include?(attrs["id"])
          @skipped[:already_linked] += 1
          return nil
        end

        email = attrs["email"].to_s.strip.downcase
        hash = attrs["old_encrypted_password"].to_s

        unless EMAIL_GRAMMAR.match?(email)
          @skipped[:invalid_email] += 1
          return nil
        end

        unless BCRYPT_GRAMMAR.match?(hash)
          @skipped[:invalid_hash] += 1
          return nil
        end

        {
          "localId" => self.class.uid_for(attrs["id"]),
          "email" => email,
          # Honest: these addresses were never confirmed. It costs nothing --
          # PR 1 links these users by uid, not by email, so verification status
          # is irrelevant to them reaching their own account.
          "emailVerified" => false,
          "passwordHash" => encode_hash(hash),
          "createdAt" => (attrs["created_at"].to_time.to_i * 1000).to_s
        }
      end

      # Firebase's import format carries passwordHash base64url-encoded without
      # padding. CONFIRMED BY THE CANARY IMPORT, not by documentation -- if a
      # single-record canary fails to authenticate, this method is the one place
      # to change (plain Base64.strict_encode64, or the raw string).
      def encode_hash(hash)
        Base64.urlsafe_encode64(hash, padding: false)
      end

      def write(records)
        File.open(@output_path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
          f.write(JSON.pretty_generate({"users" => records}))
        end
      end

      def assert_safe_output_path!
        self.class.assert_safe_output_path!(@output_path)
      end

      def cohort
        LegacyBooks::User
          .where(migrated: [false, nil])
          .where(external_provider: nil)
          .where("old_encrypted_password IS NOT NULL AND old_encrypted_password <> ''")
          .where("email IS NOT NULL AND email <> ''")
      end

      # Stubbed in tests so the legacy connection never opens. No order is
      # applied here on purpose -- find_each would discard it; rank_for decides
      # duplicate winners instead.
      def legacy_each(&block)
        cohort.find_each(batch_size: BATCH_SIZE) { |record| block.call(record.attributes) }
      end
    end
  end
end
