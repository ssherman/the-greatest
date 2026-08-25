# frozen_string_literal: true

require "digest"

# Derives the test database name from the checkout it is running in, so that
# every git worktree gets test databases of its own.
#
# config/database.yml is identical in every checkout, so without this every
# worktree resolves to the same `the_greatest_test` -- and to the same
# `the_greatest_test-0..N` databases that parallelize() fans out to. Two agents
# running `bin/rails test` at once then truncate each other's fixtures, which
# shows up as phantom failures (missing routes, nil controllers) in a suite
# that is actually green.
#
# Deliberately derived from the path rather than read from an env var: a fresh
# worktree of this repo starts without web-app/.env, so a name that has to be
# set per worktree would eventually be forgotten -- and forgetting it fails
# silently, straight back into the collision this exists to prevent.
#
# Plain file, required by absolute path: database.yml is evaluated long before
# Zeitwerk exists, so this cannot live in app/lib. It must also stay free of
# Rails dependencies -- bin/prune-worktree-test-dbs.sh requires it under bare
# ruby to map a worktree to its databases without booting the app.
module TestDatabaseName
  BASE = "the_greatest_test"

  # The checkout the un-suffixed name belongs to: the main working tree, and
  # CI, which clones into a directory of the same name.
  CANONICAL_CHECKOUT = "the_greatest"

  # Postgres truncates identifiers past 63 bytes without raising, which would
  # let two long worktree names collapse into one database -- the exact silent
  # collision this module exists to prevent. Budget 3 bytes below the limit for
  # the "-0".."-31" suffix parallelize() appends to whatever we return.
  MAX_BYTES = 60

  def self.for(rails_root)
    slug = slug_for(rails_root)
    return BASE if slug == CANONICAL_CHECKOUT

    fit("#{BASE}_#{slug}", rails_root)
  end

  # The Rails app sits in web-app/, so the checkout is one level up.
  def self.slug_for(rails_root)
    File.basename(File.dirname(File.expand_path(rails_root.to_s)))
      .downcase
      .gsub(/[^a-z0-9]+/, "_")
  end
  private_class_method :slug_for

  # Truncating alone could map two long names onto one database, so the part
  # that survives carries a digest of the full path to keep them apart.
  def self.fit(name, rails_root)
    return name if name.bytesize <= MAX_BYTES

    digest = Digest::SHA256.hexdigest(File.expand_path(rails_root.to_s))[0, 6]
    "#{name.byteslice(0, MAX_BYTES - digest.bytesize - 1)}_#{digest}"
  end
  private_class_method :fit
end
