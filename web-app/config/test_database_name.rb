# frozen_string_literal: true

require "digest"

# Derives the test database name from the checkout it is running in, so that
# every git worktree gets test databases of its own.
#
# config/database.yml is identical in every checkout, so without this every
# worktree resolves to the same `the_greatest_test` -- and to the same
# `the_greatest_test_0..N` databases that parallelize() fans out to. Two agents
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

  # parallelize() appends "_0".."_31" to whatever we return -- an underscore,
  # the same character slug_for uses for everything Postgres will not take in a
  # bare identifier. So a worktree name is terminated with a marker no worker
  # name can end in: worktree "feature" owns the worker database
  # the_greatest_test_feature_1, and without this worktree "feature-1" would
  # claim that exact name as its own. Both are plausible branch names. A base
  # name always ends in MARKER, a worker name always ends in a digit, so the
  # two can never meet.
  MARKER = "_wt"

  # Postgres truncates identifiers past 63 bytes without raising, which would
  # let two long worktree names collapse into one database -- the same silent
  # collision by another route. What we return has to leave room for both the
  # worker suffix and the marker.
  MAX_BYTES = 63
  WORKER_SUFFIX_BYTES = 3
  BUDGET = MAX_BYTES - WORKER_SUFFIX_BYTES - MARKER.bytesize

  def self.for(rails_root)
    slug = slug_for(rails_root)
    return BASE if slug == CANONICAL_CHECKOUT

    "#{fit("#{BASE}_#{slug}", rails_root)}#{MARKER}"
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
    return name if name.bytesize <= BUDGET

    digest = Digest::SHA256.hexdigest(File.expand_path(rails_root.to_s))[0, 6]
    "#{name.byteslice(0, BUDGET - digest.bytesize - 1)}_#{digest}"
  end
  private_class_method :fit
end
