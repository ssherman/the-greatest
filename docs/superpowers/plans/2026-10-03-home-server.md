# Home Server (Proxmox) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the Open Library API and the page fetcher on Shane's Proxmox box, behind Cloudflare Tunnels and Access, rebuilt from this repo by one script, and called from production Rails.

**Architecture:** An idempotent bash script (`deployment/home-server/provision`) run from the dev machine over SSH converges the Proxmox host (repos, IPv4, a private NAT bridge, firewall) and creates two Debian 13 VMs from a cloud image. Cloud-init hands each VM to scripts in its own clone of the repo: systemd timers deploy from git every 15 minutes, build and promote Open Library data daily, ping healthchecks.io, and reboot for updates. Rails gains a `CloudflareAccess::Credentials` value object that both clients send as headers.

**Tech Stack:** Bash, Proxmox VE 9.2 (`qm`, `pvesm`, `pve-firewall`, ifupdown2), cloud-init, Docker Compose v2, systemd timers, SOPS + age, Python 3.12 + Typer (data-sources), Rails 8 + Faraday 2.14 + Minitest/WebMock.

**Spec:** `docs/superpowers/specs/2026-10-03-home-server-design.md`. Read it before any task. Section references below (§4, §6) point into it.

## Global Constraints

- **This is a public repo. Never commit the house's IPv6 address, its `/64`, or any token.** The host address lives only in `secrets/home-server.env` (SOPS). The LAN ranges reach the firewall at provision time, read off the host, never from a committed file.
- Never commit to `main`. Work happens on branch `worktree-home-server` in `.claude/worktrees/home-server`. Push only after asking Shane (Task 8 asks).
- Cloudflare settings are Shane's, done in his own tool. No task here creates a tunnel, an Access application or a rule. Task 12 hands him the checklist from spec §7.
- VMIDs: `ol` = 110, `fetcher` = 120, MusicBrainz reserved = 130 (never created here).
- Sizes (spec §5): `ol` 8 vCPU / 16384 MB / 32 GB OS disk / 300 GB data disk; `fetcher` 4 vCPU / 4096 MB / 40 GB OS disk. `balloon 0` on both. `cpu host`.
- `vmbr1` = `10.20.0.0/24`, host `10.20.0.1`, fetcher `10.20.0.10`, IPv4 only. Fetcher DNS `1.1.1.1 1.0.0.1`.
- Inside `ol`: `OL_API_MEMORY_LIMIT` 6GB; build `--memory-limit 8GB`, `cpus: 6`; data at `/srv/ol-data`.
- Hostnames: `ol-api.thegreatestbooks.org`, `page-fetcher.thegreatestbooks.org`.
- Rails ENV: `CLOUDFLARE_ACCESS_CLIENT_ID`, `CLOUDFLARE_ACCESS_CLIENT_SECRET` (one pair, both clients). Both or neither, else `ConfigurationError`. The secret never appears in a log or exception message.
- The host never reboots itself. Guests reboot at 05:30 only when `/run/reboot-required` exists and no build holds `/run/ol-build.lock`.
- Rails checks: `cd web-app && bin/rails test && bundle exec standardrb`. Python: `cd data-sources && uv run pytest && uv run ruff check . && uv run ruff format --check .`. Shell: `deployment/home-server/test/run.sh`. Never run brakeman.
- SOPS: `export SOPS_AGE_KEY_FILE=~/.config/sops/age/production.txt` before any `sops` command.
- Remote commands against the box are real changes to Shane's server. Tasks 5–11 run them; every risky one goes through the commit-confirm helper (Task 5) so a lockout reverts itself.

## Review Focus

1. **The data disk is missing or unmounted.** It mounts with `nofail`, so boot survives; a build must then refuse instead of filling the 32 GB OS disk. Covered: `ol_refresh_test.sh` "unmounted data disk".
2. **Open Library is mid-publication (the six dumps disagree on a date).** That's a normal state for a few hours a month, not a failure: `next-action` prints `skip mismatch`, refresh pings success. Covered: `test_versions.py::test_next_action_reports_a_mismatch_as_a_skip` and `ol_refresh_test.sh` "mismatch".
3. **A merge whose image fails to build.** The running container and `deployed-sha` must be untouched, and the next run must retry. Covered: `deploy_test.sh` "failed build".
4. **The first build promotes a version the API can't serve, and there is no old version.** Leaving `current-version` in place would make every deploy start a crash-looping API. Covered: `ol_refresh_test.sh` "first promotion fails".
5. **A firewall probe that fails for everyone proves nothing.** Each egress target must first be reached from the `ol` VM (positive control) before "unreachable from the fetcher" counts. Covered: Task 9 `verify_egress`.

---

## File Structure

```
deployment/home-server/
  provision                       # entry point; parses args, sources lib/, dispatches
  .shellcheckrc                   # source-path=SCRIPTDIR
  lib/common.sh                   # logging, change tracking, host SSH, put_host, secrets
  lib/host.sh                     # converge_host_{packages,network,firewall}
  lib/vm.sh                       # vm_spec, render_*, ensure_vm, rebuild_vm, enable_tunnels
  lib/verify.sh                   # verify_all and its checks
  host/apt/proxmox.sources        # pve-no-subscription
  host/apt/20auto-upgrades
  host/apt/52unattended-upgrades-home-server
  host/network/vmbr1              # -> /etc/network/interfaces.d/vmbr1
  host/sbin/confirm-or-revert     # -> /usr/local/sbin/confirm-or-revert
  host/firewall/cluster.fw.tmpl   # LAN ipset + private ipset; datacenter policy
  host/firewall/host.fw
  host/firewall/110.fw
  host/firewall/120.fw
  cloud-init/user-data.yaml.tmpl
  compose.tunnel.yml              # cloudflared, profile "tunnel"
  compose.ol.yml                  # ol-VM production settings
  guest/lib.sh                    # paths, load_env, log, hc_ping
  guest/compose.sh                # the one docker compose invocation
  guest/first-boot.sh             # cloud-init's last step
  guest/install-units.sh
  guest/deploy.sh
  guest/ol-refresh.sh
  guest/heartbeat.sh
  guest/reboot-if-required.sh
  guest/systemd/{the-greatest-deploy,the-greatest-heartbeat,reboot-if-required,ol-refresh}.{service,timer}
  test/run.sh  test/helpers.sh
  test/{deploy,ol_refresh,timers,render,compose_config}_test.sh
secrets/home-server.env           # SOPS
.sops.yaml                        # + rule
.github/workflows/ci.yml          # + home-server job
data-sources/src/openlibrary/pipeline/versions.py
data-sources/tests/openlibrary/test_versions.py
web-app/app/lib/cloudflare_access/credentials.rb
web-app/test/lib/cloudflare_access/credentials_test.rb
web-app/app/lib/books/open_library/{configuration,base_client}.rb  (+ tests)
web-app/app/lib/page_fetcher/{configuration,client}.rb             (+ tests)
docs/features/home-server.md      # new
docs/features/{open-library-data-service,page-fetcher-service}.md, deployment/ENV.md, .env.example
```

---

### Task 1: `openlibrary.pipeline.versions`, the refresh timer's questions

**Files:**
- Create: `data-sources/src/openlibrary/pipeline/versions.py`
- Test: `data-sources/tests/openlibrary/test_versions.py`

**Interfaces:**
- Produces (CLI, run as `python -m openlibrary.pipeline.versions <cmd> --root /data`):
  - `next-action` → one stdout line: `build <date>`, `skip built <date>`, `skip failed <date>`, or `skip mismatch <detail>`. Exits non-zero only when Open Library cannot be asked (network error).
  - `status` → JSON `{"passing": [...], "failed": [...], "incomplete": [...]}`, each sorted ascending.
  - `prune --keep N [--current DATE]` → prints each removed path.
- Produces (Python): `read_status(root: Path) -> VersionStatus`, `decide(latest: str, status: VersionStatus) -> str`, `prune(root: Path, *, keep: int, current: str | None) -> list[Path]`.

- [ ] **Step 1: Write the failing tests**

```python
# data-sources/tests/openlibrary/test_versions.py
import json
from pathlib import Path

from typer.testing import CliRunner

from openlibrary.pipeline import versions
from openlibrary.pipeline.download import DumpDateMismatch
from openlibrary.pipeline.versions import VersionStatus, decide, prune, read_status


def _version(root: Path, date: str, *, gates_passed: bool | None) -> Path:
    """gates_passed None = a build that never wrote its manifest."""
    directory = root / "versions" / date
    (directory / "_staging").mkdir(parents=True)
    if gates_passed is not None:
        (directory / "manifest.json").write_text(json.dumps({"gates_passed": gates_passed}))
    return directory


def _dumps(root: Path, date: str) -> Path:
    directory = root / "dumps" / date
    directory.mkdir(parents=True)
    (directory / "ol_dump_works_x.txt.gz").write_text("x")
    return directory


def test_status_sorts_versions_by_what_their_manifest_says(tmp_path):
    _version(tmp_path, "2026-08-31", gates_passed=True)
    _version(tmp_path, "2026-07-31", gates_passed=True)
    _version(tmp_path, "2026-09-30", gates_passed=False)
    _version(tmp_path, "2026-10-31", gates_passed=None)

    status = read_status(tmp_path)

    assert status.passing == ["2026-07-31", "2026-08-31"]
    assert status.failed == ["2026-09-30"]
    assert status.incomplete == ["2026-10-31"]


def test_an_unreadable_manifest_is_incomplete_so_it_is_rebuilt_not_trusted(tmp_path):
    directory = _version(tmp_path, "2026-08-31", gates_passed=None)
    (directory / "manifest.json").write_text("{not json")

    assert read_status(tmp_path).incomplete == ["2026-08-31"]


def test_status_of_an_empty_root_is_empty(tmp_path):
    assert read_status(tmp_path) == VersionStatus(passing=[], failed=[], incomplete=[])


def test_decide_builds_a_new_date_and_skips_one_already_tried():
    status = VersionStatus(passing=["2026-08-31"], failed=["2026-09-30"], incomplete=["2026-10-31"])

    assert decide("2026-08-31", status) == "skip built 2026-08-31"
    assert decide("2026-09-30", status) == "skip failed 2026-09-30"
    assert decide("2026-10-31", status) == "build 2026-10-31"
    assert decide("2026-11-30", status) == "build 2026-11-30"


def test_prune_keeps_the_newest_passing_versions_and_the_current_one(tmp_path):
    for date in ("2026-06-30", "2026-07-31", "2026-08-31", "2026-09-30"):
        _version(tmp_path, date, gates_passed=True)

    removed = prune(tmp_path, keep=2, current="2026-06-30")

    left = sorted(p.name for p in (tmp_path / "versions").iterdir())
    assert left == ["2026-06-30", "2026-08-31", "2026-09-30"]
    assert removed == [tmp_path / "versions" / "2026-07-31"]


def test_prune_keeps_a_failed_build_until_a_newer_date_passes(tmp_path):
    _version(tmp_path, "2026-08-31", gates_passed=True)
    _version(tmp_path, "2026-09-30", gates_passed=False)

    prune(tmp_path, keep=2, current="2026-08-31")
    assert (tmp_path / "versions" / "2026-09-30").exists()

    _version(tmp_path, "2026-10-31", gates_passed=True)
    prune(tmp_path, keep=2, current="2026-10-31")
    assert not (tmp_path / "versions" / "2026-09-30").exists()


def test_prune_drops_dumps_once_their_date_is_built_or_superseded(tmp_path):
    _version(tmp_path, "2026-08-31", gates_passed=True)
    _version(tmp_path, "2026-09-30", gates_passed=False)
    _dumps(tmp_path, "2026-07-31")
    _dumps(tmp_path, "2026-08-31")
    _dumps(tmp_path, "2026-09-30")

    prune(tmp_path, keep=2, current="2026-08-31")

    # 09-30 failed and is newer than anything passing: its dumps stay for a retry.
    assert sorted(p.name for p in (tmp_path / "dumps").iterdir()) == ["2026-09-30"]


def test_next_action_prints_the_decision(tmp_path, monkeypatch):
    _version(tmp_path, "2026-08-31", gates_passed=True)
    monkeypatch.setattr(
        versions, "discover_all_dump_dates", lambda client: {"works": "2026-08-31"}
    )

    result = CliRunner().invoke(versions.app, ["next-action", "--root", str(tmp_path)])

    assert result.exit_code == 0
    assert result.stdout.strip() == "skip built 2026-08-31"


def test_next_action_reports_a_mismatch_as_a_skip(tmp_path, monkeypatch):
    def mismatch(client):
        raise DumpDateMismatch("dumps resolve to more than one date: {...}")

    monkeypatch.setattr(versions, "discover_all_dump_dates", mismatch)

    result = CliRunner().invoke(versions.app, ["next-action", "--root", str(tmp_path)])

    assert result.exit_code == 0
    assert result.stdout.startswith("skip mismatch ")


def test_next_action_fails_when_open_library_cannot_be_asked(tmp_path, monkeypatch):
    import httpx

    def unreachable(client):
        raise httpx.ConnectError("no route")

    monkeypatch.setattr(versions, "discover_all_dump_dates", unreachable)

    result = CliRunner().invoke(versions.app, ["next-action", "--root", str(tmp_path)])

    assert result.exit_code != 0


def test_status_and_prune_commands(tmp_path):
    _version(tmp_path, "2026-07-31", gates_passed=True)
    _version(tmp_path, "2026-08-31", gates_passed=True)
    runner = CliRunner()

    status = runner.invoke(versions.app, ["status", "--root", str(tmp_path)])
    assert json.loads(status.stdout) == {
        "passing": ["2026-07-31", "2026-08-31"], "failed": [], "incomplete": []
    }

    pruned = runner.invoke(versions.app, ["prune", "--root", str(tmp_path), "--keep", "1"])
    assert pruned.exit_code == 0
    assert pruned.stdout.strip() == str(tmp_path / "versions" / "2026-07-31")
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd data-sources && uv run pytest tests/openlibrary/test_versions.py -q`
Expected: collection error, `ModuleNotFoundError: No module named 'openlibrary.pipeline.versions'`.

- [ ] **Step 3: Implement**

```python
# data-sources/src/openlibrary/pipeline/versions.py
"""What the home server's refresh timer asks before and after a build.

The pipeline never decides whether to build or what to serve: the `ol` VM's
refresh script does (deployment/home-server/guest/ol-refresh.sh), by running
these commands inside this image:

    next-action   is the newest published dump new to this box?
    status        which versions passed, failed, or never finished
    prune         drop versions and dumps the box no longer needs

A version's own manifest.json records how its build went (`gates_passed`), so
there is no separate state file to drift from it.
"""

from __future__ import annotations

import json
import shutil
from dataclasses import asdict, dataclass
from pathlib import Path

import httpx
import typer

from .download import DumpDateMismatch, discover_all_dump_dates

app = typer.Typer(add_completion=False)


@dataclass(frozen=True)
class VersionStatus:
    passing: list[str]
    failed: list[str]
    # No readable manifest: a build that never finished. Rebuilt, never trusted.
    incomplete: list[str]


def read_status(root: Path) -> VersionStatus:
    passing: list[str] = []
    failed: list[str] = []
    incomplete: list[str] = []
    versions_dir = root / "versions"
    if versions_dir.is_dir():
        for directory in sorted(d for d in versions_dir.iterdir() if d.is_dir()):
            try:
                manifest = json.loads((directory / "manifest.json").read_text())
            except (FileNotFoundError, json.JSONDecodeError):
                incomplete.append(directory.name)
                continue
            (passing if manifest.get("gates_passed") is True else failed).append(directory.name)
    return VersionStatus(passing=passing, failed=failed, incomplete=incomplete)


def decide(latest: str, status: VersionStatus) -> str:
    if latest in status.passing:
        return f"skip built {latest}"
    if latest in status.failed:
        return f"skip failed {latest}"
    return f"build {latest}"


def prune(root: Path, *, keep: int, current: str | None) -> list[Path]:
    status = read_status(root)
    keep_versions = set(status.passing[-keep:]) if keep > 0 else set()
    if current:
        keep_versions.add(current)
    newest_passing = status.passing[-1] if status.passing else None

    def superseded(date: str) -> bool:
        return newest_passing is not None and date < newest_passing

    doomed = [d for d in status.passing if d not in keep_versions]
    # A failed or unfinished date keeps its _staging until a newer date passes:
    # it is what explains the failure.
    doomed += [d for d in status.failed + status.incomplete if superseded(d)]

    removed: list[Path] = []
    for date in sorted(doomed):
        path = root / "versions" / date
        shutil.rmtree(path)
        removed.append(path)

    dumps_dir = root / "dumps"
    if dumps_dir.is_dir():
        for directory in sorted(d for d in dumps_dir.iterdir() if d.is_dir()):
            if directory.name in status.passing or superseded(directory.name):
                shutil.rmtree(directory)
                removed.append(directory)
    return removed


@app.command("next-action")
def next_action_command(root: Path = typer.Option(..., "--root")) -> None:  # noqa: B008
    try:
        with httpx.Client(timeout=30.0, follow_redirects=True) as client:
            dates = discover_all_dump_dates(client)
    except DumpDateMismatch as exc:
        # Open Library is mid-publication; tomorrow's run will see one date.
        typer.echo(f"skip mismatch {exc}")
        return
    typer.echo(decide(next(iter(dates.values())), read_status(root)))


@app.command("status")
def status_command(root: Path = typer.Option(..., "--root")) -> None:  # noqa: B008
    typer.echo(json.dumps(asdict(read_status(root))))


@app.command("prune")
def prune_command(
    root: Path = typer.Option(..., "--root"),  # noqa: B008
    keep: int = typer.Option(2, "--keep"),
    current: str | None = typer.Option(None, "--current"),
) -> None:
    for path in prune(root, keep=keep, current=current):
        typer.echo(str(path))


if __name__ == "__main__":
    app()
```

- [ ] **Step 4: Run the tests and the linters**

Run: `cd data-sources && uv run pytest tests/openlibrary/test_versions.py -q && uv run ruff check . && uv run ruff format --check .`
Expected: all pass. If ruff flags `# noqa: B008` as unused (`RUF100` is not selected, so it won't), leave them: they match `build.py`'s style.

- [ ] **Step 5: Run the whole Python suite**

Run: `cd data-sources && uv run pytest`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add data-sources/src/openlibrary/pipeline/versions.py data-sources/tests/openlibrary/test_versions.py
git commit -m "data-sources: versions CLI for the home server's refresh timer"
```

---

### Task 2: Cloudflare Access credentials in both Rails clients

**Files:**
- Create: `web-app/app/lib/cloudflare_access/credentials.rb`
- Create: `web-app/test/lib/cloudflare_access/credentials_test.rb`
- Modify: `web-app/app/lib/books/open_library/configuration.rb`, `web-app/app/lib/books/open_library/base_client.rb`
- Modify: `web-app/app/lib/page_fetcher/configuration.rb`, `web-app/app/lib/page_fetcher/client.rb`
- Test: `web-app/test/lib/books/open_library/{configuration,base_client}_test.rb`, `web-app/test/lib/page_fetcher/{configuration,client}_test.rb`
- Modify: `.env.example`, `deployment/ENV.md`

**Interfaces:**
- Produces: `CloudflareAccess::Credentials.from_env`, `.new(client_id:, client_secret:)`, `#configured?`, `#partial?`, `#headers -> Hash`, `#inspect` (never shows the secret).
- Produces: `Books::OpenLibrary::Configuration#access` and `PageFetcher::Configuration#access` (a `Credentials`), both accepting an `access:` keyword.

- [ ] **Step 1: Write the failing credentials test**

```ruby
# web-app/test/lib/cloudflare_access/credentials_test.rb
# frozen_string_literal: true

require "test_helper"

module CloudflareAccess
  class CredentialsTest < ActiveSupport::TestCase
    def setup
      @original = ENV.to_h.slice("CLOUDFLARE_ACCESS_CLIENT_ID", "CLOUDFLARE_ACCESS_CLIENT_SECRET")
    end

    def teardown
      %w[CLOUDFLARE_ACCESS_CLIENT_ID CLOUDFLARE_ACCESS_CLIENT_SECRET].each { |k| ENV.delete(k) }
      @original.each { |k, v| ENV[k] = v }
    end

    test "both halves produce the two Access headers" do
      credentials = Credentials.new(client_id: "id.access", client_secret: "s3cret")

      assert credentials.configured?
      assert_not credentials.partial?
      assert_equal({"CF-Access-Client-Id" => "id.access", "CF-Access-Client-Secret" => "s3cret"}, credentials.headers)
    end

    test "neither half is unconfigured and sends no headers" do
      credentials = Credentials.new(client_id: nil, client_secret: "")

      assert_not credentials.configured?
      assert_not credentials.partial?
      assert_equal({}, credentials.headers)
    end

    test "one half alone is partial and sends no headers" do
      credentials = Credentials.new(client_id: "id.access", client_secret: " ")

      assert credentials.partial?
      assert_not credentials.configured?
      assert_equal({}, credentials.headers)
    end

    test "from_env reads both variables" do
      ENV["CLOUDFLARE_ACCESS_CLIENT_ID"] = "id.access"
      ENV["CLOUDFLARE_ACCESS_CLIENT_SECRET"] = "s3cret"

      assert_equal "s3cret", Credentials.from_env.headers["CF-Access-Client-Secret"]
    end

    test "inspect and to_s never show the secret" do
      credentials = Credentials.new(client_id: "id.access", client_secret: "s3cret")

      assert_not_includes credentials.inspect, "s3cret"
      assert_not_includes credentials.to_s, "s3cret"
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd web-app && bin/rails test test/lib/cloudflare_access/credentials_test.rb`
Expected: FAIL, `NameError: uninitialized constant CloudflareAccess`.

- [ ] **Step 3: Implement `Credentials`**

```ruby
# web-app/app/lib/cloudflare_access/credentials.rb
# frozen_string_literal: true

module CloudflareAccess
  # The service token Rails presents to the Cloudflare Access applications in
  # front of the home server's tunnels (docs/features/home-server.md). Both
  # halves or neither: a client sending one gets Access's login page back.
  class Credentials
    attr_reader :client_id, :client_secret

    def self.from_env
      new(client_id: ENV["CLOUDFLARE_ACCESS_CLIENT_ID"], client_secret: ENV["CLOUDFLARE_ACCESS_CLIENT_SECRET"])
    end

    def initialize(client_id:, client_secret:)
      @client_id = client_id.presence
      @client_secret = client_secret.presence
    end

    def configured?
      !client_id.nil? && !client_secret.nil?
    end

    def partial?
      client_id.nil? != client_secret.nil?
    end

    def headers
      return {} unless configured?

      {"CF-Access-Client-Id" => client_id, "CF-Access-Client-Secret" => client_secret}
    end

    # The secret must never reach a log line or an exception message.
    def inspect
      "#<#{self.class.name} configured=#{configured?}>"
    end
    alias_method :to_s, :inspect
  end
end
```

- [ ] **Step 4: Run it, plus the zeitwerk check for the new directory**

Run: `cd web-app && bin/rails test test/lib/cloudflare_access/credentials_test.rb && CI=1 bin/rails zeitwerk:check`
Expected: PASS; `All is good!`.

- [ ] **Step 5: Write the failing configuration tests**

Add to `web-app/test/lib/books/open_library/configuration_test.rb` (inside the class; extend `setup`/`teardown` to save and restore the two Access variables the same way `CredentialsTest` does):

```ruby
      test "reads Cloudflare Access credentials from the environment" do
        ENV["CLOUDFLARE_ACCESS_CLIENT_ID"] = "id.access"
        ENV["CLOUDFLARE_ACCESS_CLIENT_SECRET"] = "s3cret"

        assert Books::OpenLibrary::Configuration.new.access.configured?
      end

      test "an explicit access wins over the environment" do
        ENV["CLOUDFLARE_ACCESS_CLIENT_ID"] = "id.access"
        ENV["CLOUDFLARE_ACCESS_CLIENT_SECRET"] = "s3cret"
        none = CloudflareAccess::Credentials.new(client_id: nil, client_secret: nil)

        assert_not Books::OpenLibrary::Configuration.new(access: none).access.configured?
      end

      test "rejects half of an Access pair without echoing it" do
        ENV["CLOUDFLARE_ACCESS_CLIENT_ID"] = ""
        ENV["CLOUDFLARE_ACCESS_CLIENT_SECRET"] = "s3cret"

        error = assert_raises(Books::OpenLibrary::Exceptions::ConfigurationError) { Books::OpenLibrary::Configuration.new }
        assert_not_includes error.message, "s3cret"
      end
```

Add the same three tests to `web-app/test/lib/page_fetcher/configuration_test.rb`, with `PageFetcher::Configuration` and `PageFetcher::Exceptions::ConfigurationError`, and the same setup/teardown additions.

- [ ] **Step 6: Run them to verify they fail**

Run: `cd web-app && bin/rails test test/lib/books/open_library/configuration_test.rb test/lib/page_fetcher/configuration_test.rb`
Expected: FAIL, `NoMethodError: undefined method 'access'` / `unknown keyword: :access`.

- [ ] **Step 7: Implement in both configurations**

In `web-app/app/lib/books/open_library/configuration.rb`:

```ruby
      attr_accessor :base_url, :user_agent, :timeout, :open_timeout, :resolve_timeout, :logger, :access

      def initialize(base_url: nil, timeout: nil, open_timeout: nil, resolve_timeout: nil, user_agent: nil, logger: nil, access: nil)
        # ...existing assignments unchanged...
        @access = access.nil? ? CloudflareAccess::Credentials.from_env : access

        validate_configuration!
      end
```

and at the top of `validate_configuration!`:

```ruby
        if access.partial?
          raise Exceptions::ConfigurationError,
            "CLOUDFLARE_ACCESS_CLIENT_ID and CLOUDFLARE_ACCESS_CLIENT_SECRET must both be set, or neither"
        end
```

Make the identical change to `web-app/app/lib/page_fetcher/configuration.rb` (`attr_accessor :base_url, :open_timeout, :user_agent, :logger, :access`, `access: nil` keyword, the same assignment and the same check).

- [ ] **Step 8: Run the configuration tests**

Run: `cd web-app && bin/rails test test/lib/books/open_library/configuration_test.rb test/lib/page_fetcher/configuration_test.rb`
Expected: PASS.

- [ ] **Step 9: Write the failing client tests**

Add to `web-app/test/lib/page_fetcher/client_test.rb`:

```ruby
    def access
      CloudflareAccess::Credentials.new(client_id: "id.access", client_secret: "s3cret")
    end

    test "sends the Cloudflare Access headers when configured" do
      config = PageFetcher::Configuration.new(base_url: BASE_URL, access: access)
      client = PageFetcher::Client.new(config: config, breaker: @breaker)
      stub_request(:post, FETCH_URL).to_return(status: 200, body: page_body)

      client.fetch(PAGE_URL)

      assert_requested :post, FETCH_URL, headers: {"CF-Access-Client-Id" => "id.access", "CF-Access-Client-Secret" => "s3cret"}
    end

    test "sends no Access headers when not configured" do
      none = CloudflareAccess::Credentials.new(client_id: nil, client_secret: nil)
      client = PageFetcher::Client.new(config: PageFetcher::Configuration.new(base_url: BASE_URL, access: none), breaker: @breaker)
      stub_request(:post, FETCH_URL).to_return(status: 200, body: page_body)

      client.fetch(PAGE_URL)

      assert_requested(:post, FETCH_URL) { |req| !req.headers.key?("Cf-Access-Client-Id") && !req.headers.key?("Cf-Access-Client-Secret") }
    end

    test "never writes the Access secret to the request log" do
      log = StringIO.new
      config = PageFetcher::Configuration.new(base_url: BASE_URL, access: access, logger: Logger.new(log))
      client = PageFetcher::Client.new(config: config, breaker: @breaker)
      stub_request(:post, FETCH_URL).to_return(status: 200, body: page_body)

      client.fetch(PAGE_URL)

      assert_includes log.string, "CF-Access-Client-Id"
      assert_not_includes log.string, "s3cret"
    end
```

Add the equivalent three tests to `web-app/test/lib/books/open_library/base_client_test.rb`, using `Books::OpenLibrary::Configuration.new(base_url: BASE_URL, access: ...)`, `Books::OpenLibrary::BaseClient.new(config, breaker: @breaker)`, and `stub_request(:get, "#{BASE_URL}/works/OL1W").to_return(status: 200, body: "{}")` with `client.get("/works/OL1W")`.

WebMock normalizes header names (`Cf-Access-Client-Id`), which is why the negative test checks that spelling.

- [ ] **Step 10: Run them to verify they fail**

Run: `cd web-app && bin/rails test test/lib/page_fetcher/client_test.rb test/lib/books/open_library/base_client_test.rb`
Expected: FAIL. The headers aren't sent yet, and the log test fails on the missing `CF-Access-Client-Id`.

- [ ] **Step 11: Implement in both connections**

In `web-app/app/lib/page_fetcher/client.rb` `build_connection`, and identically in `web-app/app/lib/books/open_library/base_client.rb` `build_connection`, add the headers after `Accept` and replace the logger line:

```ruby
        config.access.headers.each { |name, value| conn.headers[name] = value }
        # bodies: false -- a response body is a whole page of HTML (spec §6).
        if config.logger
          conn.response :logger, config.logger, bodies: false do |logger|
            # Faraday logs request headers as `Name: "value"`.
            logger.filter(/(CF-Access-Client-Secret: )"[^"]*"/, '\1"[FILTERED]"')
          end
        end
```

(Keep each file's existing comment above its logger line. The base client has none.)

- [ ] **Step 12: Run the client tests, then everything**

Run: `cd web-app && bin/rails test test/lib/page_fetcher test/lib/books/open_library test/lib/cloudflare_access && bin/rails test && bundle exec standardrb`
Expected: PASS, no new warnings.

- [ ] **Step 13: Document the variables**

In `.env.example`, replace the two "Not deployed yet" comments with the current posture and add the pair:

```bash
# Open Library data service (data-sources/). Backend only -- never on a public
# request path. Production reaches it through a Cloudflare Tunnel on the home
# server (docs/features/home-server.md); development runs it locally.
OPEN_LIBRARY_SERVICE_URL=http://127.0.0.1:8080

# Page fetcher service (data-sources/, docs/features/page-fetcher-service.md).
# Same posture and the same home server as the Open Library service above.
PAGE_FETCHER_SERVICE_URL=http://127.0.0.1:8081

# Cloudflare Access service token for both services above, in production only.
# Both or neither: one alone fails at startup. Leave blank in development.
CLOUDFLARE_ACCESS_CLIENT_ID=
CLOUDFLARE_ACCESS_CLIENT_SECRET=
```

In `deployment/ENV.md`, add a section in the existing format:

```markdown
### Home server data services

#### OPEN_LIBRARY_SERVICE_URL
- **Description**: Open Library data service base URL
- **Required**: Yes, for books imports
- **Value**: `https://ol-api.thegreatestbooks.org`
- **Used By**: web, worker

#### PAGE_FETCHER_SERVICE_URL
- **Description**: Page fetcher service base URL
- **Required**: Yes, for page fetches
- **Value**: `https://page-fetcher.thegreatestbooks.org`
- **Used By**: web, worker

#### CLOUDFLARE_ACCESS_CLIENT_ID / CLOUDFLARE_ACCESS_CLIENT_SECRET
- **Description**: The `prod-rails` Access service token, sent by both clients (docs/features/home-server.md)
- **Required**: Yes, both, in production; neither in development
- **Used By**: web, worker
- **Security**: Never commit; lives in `secrets/.env.production`
```

- [ ] **Step 14: Commit**

```bash
git add web-app/app/lib/cloudflare_access web-app/test/lib/cloudflare_access web-app/app/lib/books/open_library web-app/app/lib/page_fetcher web-app/test/lib/books/open_library web-app/test/lib/page_fetcher .env.example deployment/ENV.md
git commit -m "Rails: send Cloudflare Access credentials from both data-service clients"
```

---

### Task 3: Guest scripts, systemd units and their tests

**Files:**
- Create: everything under `deployment/home-server/guest/`, `deployment/home-server/.shellcheckrc`
- Create: `deployment/home-server/test/{run.sh,helpers.sh,deploy_test.sh,ol_refresh_test.sh,timers_test.sh}`
- Modify: `.github/workflows/ci.yml` (new `home-server` job)

**Interfaces:**
- Consumes: Task 1's CLI (`next-action`, `status`, `prune`), called through `$COMPOSE run --rm --no-deps -T build python -m openlibrary.pipeline.versions <cmd> --root /data`.
- Produces: `/etc/the-greatest/home-server.env` keys the scripts read: `ROLE` (`ol`|`fetcher`), `REPO_REF`, `TUNNELS_ENABLED` (`0`|`1`), `TUNNEL_TOKEN`, `HC_HEARTBEAT`, `HC_DEPLOY`, `HC_REFRESH`. Task 4 renders this file.
- Produces: `$STATE_DIR/force-deploy` marker (provision touches it, then `systemctl start the-greatest-deploy.service`); `$OL_DATA/current-version`; lock `/run/ol-build.lock`.
- Every path in `guest/lib.sh` is overridable by environment (`REPO_DIR`, `ENV_FILE`, `STATE_DIR`, `OL_DATA`, `BUILD_LOCK`, `COMPOSE`, `INSTALL_UNITS`, `SYSTEMD_DIR`, `REBOOT_FLAG`, `API_URL`, `PROMOTE_TIMEOUT_S`, `POLL_S`). That's how the tests run them.

- [ ] **Step 1: Write `guest/lib.sh` and `.shellcheckrc`**

```bash
# deployment/home-server/guest/lib.sh
# shellcheck shell=bash
# Shared by the scripts the home-server VMs run (docs/features/home-server.md).
# Sourced, never executed. Every path can be overridden, which is how
# deployment/home-server/test/ runs these scripts against a temp directory.
# The sourcing script sets $here first.

REPO_DIR="${REPO_DIR:-/opt/the-greatest}"
ENV_FILE="${ENV_FILE:-/etc/the-greatest/home-server.env}"
STATE_DIR="${STATE_DIR:-/var/lib/the-greatest}"
OL_DATA="${OL_DATA:-/srv/ol-data}"
BUILD_LOCK="${BUILD_LOCK:-/run/ol-build.lock}"
COMPOSE="${COMPOSE:-$here/compose.sh}"

# ROLE, REPO_REF, TUNNELS_ENABLED, TUNNEL_TOKEN, HC_HEARTBEAT, HC_DEPLOY, HC_REFRESH
load_env() {
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
}

log() { printf '%s %s\n' "$(date -Is)" "$*"; }

# hc_ping <url> [start|fail] [message]: report to healthchecks.io. A blank url
# (not configured yet) is a no-op, and an undeliverable ping is logged, never
# fatal: an outage of the monitor must not fail the thing it monitors.
hc_ping() {
  local url="${1:-}" suffix="${2:-}" message="${3:-}"
  [ -n "$url" ] || return 0
  if [ -n "$suffix" ]; then url="$url/$suffix"; fi
  curl -fsS -m 10 --retry 3 -o /dev/null --data-raw "$message" "$url" || log "could not ping $url"
}
```

```
# deployment/home-server/.shellcheckrc
source-path=SCRIPTDIR
external-sources=true
```

- [ ] **Step 2: Write `guest/compose.sh` and `guest/first-boot.sh`**

```bash
#!/usr/bin/env bash
# deployment/home-server/guest/compose.sh
# docker compose with this VM's files and settings. Every guest script goes
# through here, so the invocation lives in one place.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
load_env

export COMPOSE_PROJECT_NAME=the-greatest OL_DATA_HOST="$OL_DATA"
if [ "${TUNNELS_ENABLED:-0}" = 1 ]; then export COMPOSE_PROFILES=tunnel; fi
# The refresh script passes OL_DATA_VERSION explicitly while promoting.
if [ -z "${OL_DATA_VERSION:-}" ] && [ -f "$OL_DATA/current-version" ]; then
  OL_DATA_VERSION="$(cat "$OL_DATA/current-version")"
  export OL_DATA_VERSION
fi

hs="$REPO_DIR/deployment/home-server"
files=(-f "$REPO_DIR/data-sources/docker-compose.yml" -f "$hs/compose.tunnel.yml")
if [ -f "$hs/compose.$ROLE.yml" ]; then files+=(-f "$hs/compose.$ROLE.yml"); fi
exec docker compose "${files[@]}" "$@"
```

```bash
#!/usr/bin/env bash
# deployment/home-server/guest/first-boot.sh
# cloud-init's last step (cloud-init/user-data.yaml.tmpl), after Docker is
# installed and the repo is cloned. Also runs on a rebuilt VM's first boot.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
load_env
mkdir -p "$STATE_DIR"

case "$ROLE" in
  ol)
    disk=/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1
    # Format only a blank disk: a rebuilt VM keeps the data it had (spec §5).
    blkid "$disk" >/dev/null || mkfs.ext4 -q -L ol-data "$disk"
    mkdir -p "$OL_DATA"
    # nofail: a missing disk must not hang boot; ol-refresh.sh refuses to build instead.
    grep -q '^LABEL=ol-data ' /etc/fstab ||
      echo "LABEL=ol-data $OL_DATA ext4 defaults,discard,nofail 0 2" >>/etc/fstab
    mountpoint -q "$OL_DATA" || mount "$OL_DATA"
    ;;
  fetcher)
    # No IPv6 at all: every device in the house has a public IPv6 address (spec §4).
    printf 'net.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1\n' \
      >/etc/sysctl.d/90-no-ipv6.conf
    sysctl -q --system
    ;;
  *) echo "first-boot: unknown ROLE '$ROLE'" >&2; exit 1 ;;
esac

"$here/install-units.sh"
touch "$STATE_DIR/force-deploy"
systemctl start the-greatest-deploy.service
```

- [ ] **Step 3: Write `guest/install-units.sh` and the units**

```bash
#!/usr/bin/env bash
# deployment/home-server/guest/install-units.sh
# Installs this role's systemd units from the repo and enables their timers.
# deploy.sh runs it on every deploy, so a merged unit change reaches the VM.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
load_env
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"

units=(the-greatest-deploy the-greatest-heartbeat reboot-if-required)
case "$ROLE" in
  ol) units+=(ol-refresh) ;;
  fetcher) ;;
  *) echo "install-units: unknown ROLE '$ROLE'" >&2; exit 1 ;;
esac

changed=0
for unit in "${units[@]}"; do
  for kind in service timer; do
    if ! cmp -s "$here/systemd/$unit.$kind" "$SYSTEMD_DIR/$unit.$kind"; then
      install -m 0644 "$here/systemd/$unit.$kind" "$SYSTEMD_DIR/$unit.$kind"
      changed=1
    fi
  done
done
if [ "$changed" = 1 ]; then systemctl daemon-reload; fi
for unit in "${units[@]}"; do systemctl enable --now "$unit.timer"; done
```

`guest/systemd/the-greatest-deploy.service`:
```ini
[Unit]
Description=Deploy this VM's service from the repo (docs/features/home-server.md)
Wants=network-online.target
After=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=/opt/the-greatest/deployment/home-server/guest/deploy.sh
TimeoutStartSec=1h
```

`guest/systemd/the-greatest-deploy.timer`:
```ini
[Unit]
Description=Deploy from git every 15 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=15min

[Install]
WantedBy=timers.target
```

`guest/systemd/ol-refresh.service`:
```ini
[Unit]
Description=Build and promote the newest Open Library dump (docs/features/home-server.md)
Wants=network-online.target
After=network-online.target docker.service srv-ol\x2ddata.mount

[Service]
Type=oneshot
ExecStart=/opt/the-greatest/deployment/home-server/guest/ol-refresh.sh
TimeoutStartSec=12h
```

`guest/systemd/ol-refresh.timer`:
```ini
[Unit]
Description=Check for a new Open Library dump daily, and at boot

[Timer]
OnCalendar=*-*-* 03:00
OnBootSec=10min

[Install]
WantedBy=timers.target
```

`guest/systemd/the-greatest-heartbeat.service`:
```ini
[Unit]
Description=Ping healthchecks.io when this VM's service answers

[Service]
Type=oneshot
ExecStart=/opt/the-greatest/deployment/home-server/guest/heartbeat.sh
```

`guest/systemd/the-greatest-heartbeat.timer`:
```ini
[Unit]
Description=Heartbeat every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
```

`guest/systemd/reboot-if-required.service`:
```ini
[Unit]
Description=Reboot for installed updates unless a data build is running

[Service]
Type=oneshot
ExecStart=/opt/the-greatest/deployment/home-server/guest/reboot-if-required.sh
```

`guest/systemd/reboot-if-required.timer`:
```ini
[Unit]
Description=Nightly reboot window

[Timer]
OnCalendar=*-*-* 05:30

[Install]
WantedBy=timers.target
```

- [ ] **Step 4: Write the test helpers and the failing tests**

```bash
# deployment/home-server/test/helpers.sh
# shellcheck shell=bash
# Shared by the *_test.sh files: a temp sandbox, stub commands on PATH, and
# pass/fail counting in the style of deployment/nginx/test.
HS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$HS_DIR/../.." && pwd)"
GUEST="$HS_DIR/guest"
failures=0

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1 -- $2"; failures=$((failures + 1)); }
# check <name> <function>: the function's exit status decides; on failure the
# call log and the script's output are printed.
check() {
  if "$2"; then pass "$1"; else fail "$1" "calls: $(cat "$CALLS" 2>/dev/null) | out: $(cat "$SANDBOX/log/out" 2>/dev/null)"; fi
}
finish() {
  if [ "$failures" = 0 ]; then echo "all passed"; else echo "$failures failed"; exit 1; fi
}

new_sandbox() {
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX"/{bin,state,data/versions,run,log}
  export SANDBOX STATE_DIR="$SANDBOX/state" OL_DATA="$SANDBOX/data"
  export BUILD_LOCK="$SANDBOX/run/ol-build.lock" ENV_FILE="$SANDBOX/home-server.env"
  export CALLS="$SANDBOX/log/calls" PATH="$SANDBOX/bin:$ORIGINAL_PATH"
  : >"$CALLS"
}
ORIGINAL_PATH="$PATH"

write_env() { printf '%s\n' "$@" >"$ENV_FILE"; }

# stub <name> <body>: a command on PATH that logs "<name> <args>" to $CALLS,
# then runs body.
stub() {
  printf '#!/usr/bin/env bash\necho "%s $*" >>"$CALLS"\n%s\n' "$1" "$2" >"$SANDBOX/bin/$1"
  chmod +x "$SANDBOX/bin/$1"
}
called() { grep -qE "$1" "$CALLS"; }
```

```bash
#!/usr/bin/env bash
# deployment/home-server/test/ol_refresh_test.sh
# guest/ol-refresh.sh against a stubbed compose (the versions CLI, the build,
# the API) and a stubbed curl (healthchecks.io and the API's /version).
set -uo pipefail
# shellcheck source=helpers.sh
. "$(dirname "$0")/helpers.sh"

setup() {
  new_sandbox
  write_env ROLE=ol REPO_REF=main TUNNELS_ENABLED=0 HC_REFRESH=https://hc.test/refresh
  export PROMOTE_TIMEOUT_S=1 POLL_S=0 API_URL=http://api.test
  unset NEXT_ACTION NEXT_ACTION_FAIL BUILD_EXIT BROKEN_VERSION NOT_MOUNTED
  stub mountpoint '[ -z "${NOT_MOUNTED:-}" ]'
  stub curl 'url="${!#}"
case "$url" in
  */version) [ -f "$SANDBOX/serving" ] || exit 7; printf "{\"dump_date\":\"%s\"}" "$(cat "$SANDBOX/serving")" ;;
esac'
  stub compose 'case "$*" in
  *"versions next-action"*) [ -z "${NEXT_ACTION_FAIL:-}" ] || exit 1; echo "$NEXT_ACTION" ;;
  *"versions status"*) cat "$SANDBOX/status.json" ;;
  *"versions prune"*) ;;
  "run --rm --no-deps -T build") exit "${BUILD_EXIT:-0}" ;;
  "up -d api") if [ "$OL_DATA_VERSION" = "${BROKEN_VERSION:-}" ]; then rm -f "$SANDBOX/serving"; else echo "$OL_DATA_VERSION" >"$SANDBOX/serving"; fi ;;
  "stop api") rm -f "$SANDBOX/serving" ;;
esac'
  export COMPOSE="$SANDBOX/bin/compose"
}
status_json() { printf '%s' "$1" >"$SANDBOX/status.json"; }
serving() { echo "$1" >"$OL_DATA/current-version"; echo "$1" >"$SANDBOX/serving"; }
refresh() { "$GUEST/ol-refresh.sh" >"$SANDBOX/log/out" 2>&1; }

t_skip_built() {
  setup; serving 2026-08-31; export NEXT_ACTION="skip built 2026-08-31"
  refresh && ! called '^compose run --rm --no-deps -T build$' && called 'hc\.test/refresh$'
}
t_mismatch() {
  setup; export NEXT_ACTION="skip mismatch dumps resolve to more than one date"
  refresh && ! called '^compose run --rm --no-deps -T build$' && ! called 'refresh/fail'
}
t_promotes() {
  setup; serving 2026-08-31; export NEXT_ACTION="build 2026-09-30"
  status_json '{"passing":["2026-08-31","2026-09-30"],"failed":[],"incomplete":[]}'
  refresh && [ "$(cat "$OL_DATA/current-version")" = 2026-09-30 ] &&
    called 'versions prune --keep 2 --current 2026-09-30' && called 'hc\.test/refresh$'
}
t_gate_failure() {
  setup; serving 2026-08-31; export NEXT_ACTION="build 2026-09-30" BUILD_EXIT=1
  status_json '{"passing":["2026-08-31"],"failed":["2026-09-30"],"incomplete":[]}'
  mkdir -p "$OL_DATA/versions/2026-09-30"
  echo '{"gates":[{"name":"row_counts","status":"pass"},{"name":"evaluation_set","status":"fail"}]}' \
    >"$OL_DATA/versions/2026-09-30/build_report.json"
  ! refresh && [ "$(cat "$OL_DATA/current-version")" = 2026-08-31 ] &&
    called 'evaluation_set.*refresh/fail' && ! called '^compose up -d api$'
}
t_crash() {
  setup; serving 2026-08-31; export NEXT_ACTION="build 2026-09-30" BUILD_EXIT=137
  status_json '{"passing":["2026-08-31"],"failed":[],"incomplete":["2026-09-30"]}'
  ! refresh && [ "$(cat "$OL_DATA/current-version")" = 2026-08-31 ] &&
    called 'did not finish.*refresh/fail'
}
t_reverts() {
  setup; serving 2026-08-31; export NEXT_ACTION="build 2026-09-30" BROKEN_VERSION=2026-09-30
  status_json '{"passing":["2026-08-31","2026-09-30"],"failed":[],"incomplete":[]}'
  ! refresh && [ "$(cat "$OL_DATA/current-version")" = 2026-08-31 ] &&
    [ "$(cat "$SANDBOX/serving")" = 2026-08-31 ] && called 'refresh/fail' && ! called 'versions prune'
}
t_first_promotion_fails() {
  setup; export NEXT_ACTION="build 2026-09-30" BROKEN_VERSION=2026-09-30
  status_json '{"passing":["2026-09-30"],"failed":[],"incomplete":[]}'
  ! refresh && [ ! -f "$OL_DATA/current-version" ] && called '^compose stop api$'
}
t_lock_held() {
  setup; export NEXT_ACTION="build 2026-09-30"
  flock "$BUILD_LOCK" sleep 3 &
  sleep 0.5
  refresh; rc=$?
  wait
  [ "$rc" = 0 ] && ! called '^compose '
}
t_unmounted() {
  setup; export NEXT_ACTION="build 2026-09-30" NOT_MOUNTED=1
  ! refresh && ! called '^compose ' && called 'not mounted.*refresh/fail'
}
t_unreachable() {
  setup; export NEXT_ACTION_FAIL=1
  ! refresh && ! called '^compose run --rm --no-deps -T build$' && called 'refresh/fail'
}

check "a dump already built is a no-op that still checks in" t_skip_built
check "mismatch: Open Library mid-publication is a quiet skip" t_mismatch
check "a passing build is promoted and old versions pruned" t_promotes
check "failed gates keep the old version and name the gate" t_gate_failure
check "a build that died keeps the old version" t_crash
check "an API that will not serve the new version is reverted" t_reverts
check "first promotion fails: no current-version is left behind" t_first_promotion_fails
check "a held build lock means no second build" t_lock_held
check "an unmounted data disk refuses to build" t_unmounted
check "Open Library unreachable is a failure" t_unreachable
finish
```

```bash
#!/usr/bin/env bash
# deployment/home-server/test/deploy_test.sh
# guest/deploy.sh against a real git origin, with compose and install-units stubbed.
set -uo pipefail
# shellcheck source=helpers.sh
. "$(dirname "$0")/helpers.sh"

gitc() { git -c user.email=test@example.com -c user.name=test "$@"; }

setup() {
  new_sandbox
  origin="$SANDBOX/origin.git"; work="$SANDBOX/work"
  git init -q --bare "$origin"
  git clone -q "file://$origin" "$work" 2>/dev/null
  commit data-sources/app v1
  git clone -q --depth 1 --branch main "file://$origin" "$SANDBOX/repo"
  export REPO_DIR="$SANDBOX/repo"
  git -C "$REPO_DIR" rev-parse HEAD >"$STATE_DIR/deployed-sha"
  write_env ROLE=fetcher REPO_REF=main TUNNELS_ENABLED=0 HC_DEPLOY=https://hc.test/deploy
  unset BUILD_EXIT
  stub compose 'if [ "$1" = build ]; then exit "${BUILD_EXIT:-0}"; fi'
  stub install-units ''
  stub docker ''
  stub curl ''
  export COMPOSE="$SANDBOX/bin/compose" INSTALL_UNITS="$SANDBOX/bin/install-units"
}
commit() {
  (cd "$work" && mkdir -p "$(dirname "$1")" && echo "$2" >"$1" && git add -A &&
    gitc commit -qm "$1" && git push -q origin HEAD:main)
}
head_of_origin() { git -C "$work" rev-parse HEAD; }
deploy() { "$GUEST/deploy.sh" "$@" >"$SANDBOX/log/out" 2>&1; }

t_unwatched() {
  setup; before="$(cat "$STATE_DIR/deployed-sha")"; commit docs/readme x
  deploy && [ "$(cat "$STATE_DIR/deployed-sha")" = "$before" ] && ! called '^compose build' &&
    called 'hc\.test/deploy$'
}
t_watched() {
  setup; commit data-sources/app v2
  deploy && called '^compose build fetcher$' && called '^compose up -d --remove-orphans$' &&
    [ "$(cat "$STATE_DIR/deployed-sha")" = "$(head_of_origin)" ]
}
t_home_server_dir() {
  setup; commit deployment/home-server/compose.ol.yml x
  deploy && called '^compose build fetcher$'
}
t_failed_build() {
  setup; before="$(cat "$STATE_DIR/deployed-sha")"; commit data-sources/app v2; export BUILD_EXIT=1
  ! deploy && [ "$(cat "$STATE_DIR/deployed-sha")" = "$before" ] && ! called '^compose up' &&
    called 'deploy/fail'
}
t_retry_after_failure() {
  t_failed_build || return 1
  unset BUILD_EXIT; : >"$CALLS"
  deploy && called '^compose build fetcher$' && [ "$(cat "$STATE_DIR/deployed-sha")" = "$(head_of_origin)" ]
}
t_force_flag() { setup; deploy --force && called '^compose build fetcher$' && called '^compose up -d'; }
t_force_marker() {
  setup; touch "$STATE_DIR/force-deploy"
  deploy && called '^compose build fetcher$' && [ ! -f "$STATE_DIR/force-deploy" ]
}
t_ol_without_version() {
  setup; write_env ROLE=ol REPO_REF=main TUNNELS_ENABLED=0 HC_DEPLOY=https://hc.test/deploy
  commit data-sources/app v2
  deploy && called '^compose build api$' && ! called '^compose up'
}
t_ol_without_version_tunnels() {
  setup; write_env ROLE=ol REPO_REF=main TUNNELS_ENABLED=1 HC_DEPLOY=https://hc.test/deploy
  commit data-sources/app v2
  deploy && called '^compose up -d cloudflared$' && ! called '^compose up -d --remove-orphans$'
}
t_ol_build_running() {
  setup; write_env ROLE=ol REPO_REF=main TUNNELS_ENABLED=0 HC_DEPLOY=https://hc.test/deploy
  commit data-sources/app v2
  flock "$BUILD_LOCK" sleep 3 &
  sleep 0.5
  deploy; rc=$?
  wait
  [ "$rc" = 0 ] && ! called '^compose '
}

check "a change outside the watched paths deploys nothing" t_unwatched
check "a data-sources change builds and restarts the service" t_watched
check "a deployment/home-server change deploys too" t_home_server_dir
check "a failed build leaves the container and deployed-sha alone" t_failed_build
check "the next run retries a failed build" t_retry_after_failure
check "--force deploys without a change" t_force_flag
check "the force-deploy marker deploys once and is cleared" t_force_marker
check "ol with no data version builds but does not start api" t_ol_without_version
check "ol with no data version still starts the tunnel" t_ol_without_version_tunnels
check "ol does not deploy under a running build" t_ol_build_running
finish
```

```bash
#!/usr/bin/env bash
# deployment/home-server/test/timers_test.sh
# heartbeat.sh, reboot-if-required.sh and install-units.sh.
set -uo pipefail
# shellcheck source=helpers.sh
. "$(dirname "$0")/helpers.sh"

setup() {
  new_sandbox
  write_env ROLE=fetcher REPO_REF=main TUNNELS_ENABLED=0 HC_HEARTBEAT=https://hc.test/beat
  export REBOOT_FLAG="$SANDBOX/run/reboot-required" SYSTEMD_DIR="$SANDBOX/systemd"
  mkdir -p "$SYSTEMD_DIR"
  unset SERVICE_DOWN
  stub curl 'case "${!#}" in http://127.0.0.1:*) [ -z "${SERVICE_DOWN:-}" ] ;; esac'
  stub systemctl ''
}

t_beat_when_up() { setup; "$GUEST/heartbeat.sh" && called 'hc\.test/beat$'; }
t_silent_when_down() {
  setup; export SERVICE_DOWN=1
  "$GUEST/heartbeat.sh"; ! called 'hc\.test/beat'
}
t_ol_beats_on_version() {
  setup; write_env ROLE=ol HC_HEARTBEAT=https://hc.test/beat
  "$GUEST/heartbeat.sh" && called 'curl .*127\.0\.0\.1:8080/version'
}
t_no_flag_no_reboot() { setup; "$GUEST/reboot-if-required.sh" && ! called 'systemctl reboot'; }
t_flag_reboots() { setup; touch "$REBOOT_FLAG"; "$GUEST/reboot-if-required.sh" && called '^systemctl reboot$'; }
t_build_defers_reboot() {
  setup; touch "$REBOOT_FLAG"
  flock "$BUILD_LOCK" sleep 3 &
  sleep 0.5
  "$GUEST/reboot-if-required.sh"; rc=$?
  wait
  [ "$rc" = 0 ] && ! called 'systemctl reboot'
}
t_units_for_ol() {
  setup; write_env ROLE=ol
  "$GUEST/install-units.sh" && [ -f "$SYSTEMD_DIR/ol-refresh.timer" ] &&
    called 'systemctl daemon-reload' && called 'systemctl enable --now ol-refresh.timer'
}
t_units_for_fetcher() {
  setup; "$GUEST/install-units.sh" && [ ! -f "$SYSTEMD_DIR/ol-refresh.timer" ] &&
    [ -f "$SYSTEMD_DIR/the-greatest-deploy.timer" ]
}
t_units_idempotent() {
  setup; "$GUEST/install-units.sh" && : >"$CALLS" &&
    "$GUEST/install-units.sh" && ! called 'daemon-reload'
}

check "heartbeat pings when the service answers" t_beat_when_up
check "heartbeat stays silent when the service is down" t_silent_when_down
check "the ol heartbeat asks /version" t_ol_beats_on_version
check "no reboot-required flag, no reboot" t_no_flag_no_reboot
check "the flag reboots" t_flag_reboots
check "a running build defers the reboot" t_build_defers_reboot
check "ol gets the refresh timer" t_units_for_ol
check "fetcher does not" t_units_for_fetcher
check "a second install changes nothing" t_units_idempotent
finish
```

```bash
#!/usr/bin/env bash
# deployment/home-server/test/run.sh
# Every home-server shell test, plus shellcheck. CI runs this (home-server job).
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
hs="$(cd "$here/.." && pwd)"
if command -v shellcheck >/dev/null; then sc=(shellcheck); else sc=(uvx --from shellcheck-py shellcheck); fi

status=0
# Only files that exist yet: provision, lib/ and host/ arrive in Tasks 4-5.
files=()
for f in "$hs/provision" "$hs"/lib/*.sh "$hs"/guest/*.sh "$hs"/host/sbin/* "$here"/*.sh; do
  if [ -f "$f" ]; then files+=("$f"); fi
done
"${sc[@]}" -x "${files[@]}" || status=1
for t in "$here"/*_test.sh; do
  echo "--- $(basename "$t")"
  "$t" || status=1
done
exit "$status"
```

Make every script executable: `chmod +x deployment/home-server/guest/*.sh deployment/home-server/test/*.sh` (not `lib.sh` or `helpers.sh`; harmless if they are).

- [ ] **Step 5: Run the tests to verify they fail**

Run: `deployment/home-server/test/deploy_test.sh; deployment/home-server/test/ol_refresh_test.sh; deployment/home-server/test/timers_test.sh`
Expected: FAIL lines everywhere. `deploy.sh`, `ol-refresh.sh`, `heartbeat.sh` and `reboot-if-required.sh` don't exist yet. The `install-units` cases may already pass, since that script exists from Step 3.

- [ ] **Step 6: Implement `deploy.sh`**

```bash
#!/usr/bin/env bash
# deployment/home-server/guest/deploy.sh
# the-greatest-deploy.timer, every 15 minutes: bring this VM's service up to
# origin/$REPO_REF when anything it runs from has changed. --force, or the
# $STATE_DIR/force-deploy marker provision leaves, deploys without a change.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
load_env
INSTALL_UNITS="${INSTALL_UNITS:-$here/install-units.sh}"
WATCHED=(data-sources deployment/home-server)

force=0
if [ "${1:-}" = --force ] || [ -f "$STATE_DIR/force-deploy" ]; then force=1; fi

fail() { log "deploy failed: $1"; hc_ping "${HC_DEPLOY:-}" fail "$1"; exit 1; }

if [ "$ROLE" = ol ]; then
  # Never rebuild under a running data build, and never let one start mid-deploy.
  exec 9>"$BUILD_LOCK"
  if ! flock -n 9; then
    log "a data build is running; deploying next time"
    hc_ping "${HC_DEPLOY:-}" "" "deferred: build running"
    exit 0
  fi
fi

cd "$REPO_DIR"
git fetch --quiet --depth 1 origin "$REPO_REF" || fail "git fetch origin $REPO_REF"
target="$(git rev-parse FETCH_HEAD)"
deployed="$(cat "$STATE_DIR/deployed-sha" 2>/dev/null || true)"

needs_deploy() {
  [ "$force" = 1 ] && return 0
  [ -n "$deployed" ] || return 0
  git cat-file -e "$deployed^{commit}" 2>/dev/null || return 0
  ! git diff --quiet "$deployed" "$target" -- "${WATCHED[@]}"
}

if ! needs_deploy; then
  log "nothing to deploy (${target:0:12})"
  hc_ping "${HC_DEPLOY:-}" "" "no change"
  exit 0
fi

log "deploying ${target:0:12} (was ${deployed:0:12})"
git checkout --quiet --force --detach "$target" || fail "checkout ${target:0:12}"
"$INSTALL_UNITS" || fail "install-units"

case "$ROLE" in
  ol) service=api ;;
  fetcher) service=fetcher ;;
  *) fail "unknown ROLE '$ROLE'" ;;
esac
# A failed build leaves the running container exactly as it was.
"$COMPOSE" build "$service" || fail "image build for $service at ${target:0:12}"

if [ "$ROLE" = ol ] && [ ! -f "$OL_DATA/current-version" ]; then
  log "no Open Library version yet; ol-refresh starts api after the first build"
  if [ "${TUNNELS_ENABLED:-0}" = 1 ]; then "$COMPOSE" up -d cloudflared || fail "compose up cloudflared"; fi
else
  "$COMPOSE" up -d --remove-orphans || fail "compose up"
fi

echo "$target" >"$STATE_DIR/deployed-sha"
rm -f "$STATE_DIR/force-deploy"
docker image prune -f >/dev/null || log "image prune failed"
hc_ping "${HC_DEPLOY:-}" "" "deployed ${target:0:12}"
```

- [ ] **Step 7: Implement `ol-refresh.sh`**

```bash
#!/usr/bin/env bash
# deployment/home-server/guest/ol-refresh.sh
# ol-refresh.timer, daily at 03:00 and at boot (`ol` VM only): build the newest
# Open Library dump if this box has not tried it yet, and serve it only if
# every gate passes. Spec: docs/superpowers/specs/2026-10-03-home-server-design.md §6.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
load_env
API_URL="${API_URL:-http://127.0.0.1:8080}"
PROMOTE_TIMEOUT_S="${PROMOTE_TIMEOUT_S:-600}"
POLL_S="${POLL_S:-5}"

hc() { hc_ping "${HC_REFRESH:-}" "$@"; }
fail() { log "refresh failed: $1"; hc fail "$1"; exit 1; }
versions() { "$COMPOSE" run --rm --no-deps -T build python -m openlibrary.pipeline.versions "$@" --root /data; }

exec 9>"$BUILD_LOCK"
if ! flock -n 9; then log "a build or deploy holds $BUILD_LOCK; trying next run"; exit 0; fi

# The data disk mounts with nofail so a missing disk cannot hang boot; a build
# must then refuse, or it would fill the OS disk instead.
mountpoint -q "$OL_DATA" || fail "$OL_DATA is not mounted"

hc start
action="$(versions next-action)" || fail "could not ask Open Library for the latest dump"
log "next action: $action"
case "$action" in
  "skip "*) hc "" "$action"; exit 0 ;;
  "build "*) date="${action#build }" ;;
  *) fail "unexpected next-action output: $action" ;;
esac

log "building $date"
built=0
"$COMPOSE" run --rm --no-deps -T build && built=1
status="$(versions status)" || fail "could not read version status after building $date"

if [ "$built" = 0 ]; then
  if jq -e --arg d "$date" 'any(.failed[]; . == $d)' >/dev/null <<<"$status"; then
    gates="$(jq -r '[.gates[] | select(.status == "fail") | .name] | join(", ")' \
      "$OL_DATA/versions/$date/build_report.json" 2>/dev/null || echo unknown)"
    fail "gates failed for $date ($gates); still serving $(cat "$OL_DATA/current-version" 2>/dev/null || echo nothing)"
  fi
  fail "the build of $date did not finish; it runs again next time"
fi

new="$(jq -r '.passing[-1] // empty' <<<"$status")"
[ -n "$new" ] || fail "the build of $date exited 0 but no passing version exists"
old="$(cat "$OL_DATA/current-version" 2>/dev/null || true)"

serve() {
  printf '%s\n' "$1" >"$OL_DATA/current-version.tmp"
  mv "$OL_DATA/current-version.tmp" "$OL_DATA/current-version"
  OL_DATA_VERSION="$1" "$COMPOSE" up -d api
}
serving() { curl -fsS -m 10 "$API_URL/version" | jq -r '.dump_date'; }
wait_for() {
  local deadline=$((SECONDS + PROMOTE_TIMEOUT_S))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ "$(serving 2>/dev/null || true)" = "$1" ]; then return 0; fi
    sleep "$POLL_S"
  done
  return 1
}

serve "$new" || log "compose up on $new failed"
if ! wait_for "$new"; then
  if [ -n "$old" ]; then
    serve "$old" || log "compose up on $old failed"
    wait_for "$old" || log "the API did not come back on $old either"
  else
    # Leaving current-version would make every deploy start a crash-looping API.
    rm -f "$OL_DATA/current-version"
    "$COMPOSE" stop api || true
  fi
  fail "$new passed its gates but the API did not serve it; back on ${old:-nothing}"
fi

versions prune --keep 2 --current "$new" || log "prune failed; old versions left on disk"
hc "" "serving $new"
```

- [ ] **Step 8: Implement `heartbeat.sh` and `reboot-if-required.sh`**

```bash
#!/usr/bin/env bash
# deployment/home-server/guest/heartbeat.sh
# the-greatest-heartbeat.timer, every 5 minutes: ping healthchecks.io only if
# this VM's service answers locally. Silence is the alert.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
load_env

case "$ROLE" in
  ol) url=http://127.0.0.1:8080/version ;;
  fetcher) url=http://127.0.0.1:8081/health ;;
  *) echo "heartbeat: unknown ROLE '$ROLE'" >&2; exit 1 ;;
esac
if curl -fsS -m 10 -o /dev/null "$url"; then hc_ping "${HC_HEARTBEAT:-}"; fi
```

```bash
#!/usr/bin/env bash
# deployment/home-server/guest/reboot-if-required.sh
# reboot-if-required.timer, 05:30: reboot for installed updates, unless a data
# build holds the lock. Then it waits for the next night.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
REBOOT_FLAG="${REBOOT_FLAG:-/run/reboot-required}"

[ -f "$REBOOT_FLAG" ] || exit 0
exec 9>"$BUILD_LOCK"
if ! flock -n 9; then log "reboot required, but a build is running; trying tomorrow"; exit 0; fi
log "rebooting for installed updates"
systemctl reboot
```

- [ ] **Step 9: Run the tests until they pass**

Run: `chmod +x deployment/home-server/guest/*.sh && deployment/home-server/test/run.sh`
Expected: shellcheck clean and every test file ends with `all passed`. `run.sh` also runs `render_test.sh` and `compose_config_test.sh`, which don't exist until Task 4; the glob simply doesn't match them yet. Fix shellcheck findings in the scripts rather than disabling them, except SC1090 on `load_env`, which is disabled inline above.

- [ ] **Step 10: Add the CI job**

In `.github/workflows/ci.yml`, after the `python` job:

```yaml
  home-server:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      # The VMs deploy their own scripts from main, so a broken deploy.sh on
      # main would stop the next fix from arriving. Test them before merge.
      - name: Shell tests and shellcheck
        run: deployment/home-server/test/run.sh
```

- [ ] **Step 11: Commit**

```bash
git add deployment/home-server/guest deployment/home-server/test deployment/home-server/.shellcheckrc .github/workflows/ci.yml
git commit -m "home-server: guest deploy, refresh, heartbeat and reboot scripts with tests"
```

---

### Task 4: Compose overrides, secrets file and cloud-init template

**Files:**
- Create: `deployment/home-server/compose.tunnel.yml`, `deployment/home-server/compose.ol.yml`
- Create: `deployment/home-server/cloud-init/user-data.yaml.tmpl`
- Create: `deployment/home-server/lib/common.sh`, `deployment/home-server/lib/vm.sh` (render functions only in this task)
- Create: `secrets/home-server.env` (SOPS), modify `.sops.yaml`
- Create: `deployment/home-server/test/render_test.sh`, `deployment/home-server/test/compose_config_test.sh`

**Interfaces:**
- Consumes: the env keys from Task 3.
- Produces (`lib/vm.sh`): `vm_spec <role>` sets `VMID NAME CORES MEM OSDISK DATADISK NET IPCONFIG NAMESERVER STARTUP`; `render_vm_env <role> <out>`; `render_user_data <role> <env-file> <out>`. Globals they read: `REPO_REF`, `TUNNELS_ENABLED`, `OL_TUNNEL_TOKEN`, `FETCHER_TUNNEL_TOKEN`, `HC_OL_HEARTBEAT`, `HC_OL_DEPLOY`, `HC_OL_REFRESH`, `HC_FETCHER_HEARTBEAT`, `HC_FETCHER_DEPLOY`, `SSH_PUBKEY_FILE`.
- Produces (`lib/common.sh`): `log`, `die`, `note_change`, `CHANGES` array, `on_host`, `host_file_matches`, `put_host`, `load_secrets`, `HS_DIR`, `REPO_ROOT`.

- [ ] **Step 1: Pin the cloudflared image**

Run: `curl -s 'https://hub.docker.com/v2/repositories/cloudflare/cloudflared/tags?page_size=25' | jq -r '.results[].name' | grep -E '^[0-9]{4}\.[0-9]+\.[0-9]+$' | sort -V | tail -1`
Expected: one version such as `2026.9.1`. Use it below wherever the image tag appears. Never `latest`.

- [ ] **Step 2: Write the compose overrides**

```yaml
# deployment/home-server/compose.tunnel.yml
# The Cloudflare Tunnel connector for whichever service this VM runs
# (docs/features/home-server.md). The routing (hostname -> http://api:8080 or
# http://fetcher:8081) lives in the tunnel's dashboard configuration, so this
# file is the same on both VMs. Profile "tunnel" is on only after
# `provision --enable-tunnels`, which runs once Cloudflare Access is in place.
services:
  cloudflared:
    image: cloudflare/cloudflared:<the tag from Step 1>
    profiles: ["tunnel"]
    restart: unless-stopped
    command: ["tunnel", "--no-autoupdate", "run"]
    environment:
      TUNNEL_TOKEN: "${TUNNEL_TOKEN:-}"
```

```yaml
# deployment/home-server/compose.ol.yml
# The `ol` VM's production settings (docs/features/home-server.md), merged over
# data-sources/docker-compose.yml by guest/compose.sh. Sized for a 16 GB,
# 8-vCPU VM: 6 GB for the API's DuckDB, 8 GB for a running build, the rest is
# page cache over the artifact.
services:
  api:
    environment:
      OL_API_MEMORY_LIMIT: 6GB
  build:
    # The live API keeps 2 of the 8 vCPUs while a build runs.
    cpus: 6
    command: [python, -m, openlibrary.pipeline.build, --root, /data, --memory-limit, 8GB]
```

(Substitute the real tag. The angle brackets must not survive into the file; `compose_config_test.sh` checks this.)

- [ ] **Step 3: Write `compose_config_test.sh` and run it**

```bash
#!/usr/bin/env bash
# deployment/home-server/test/compose_config_test.sh
# The merged compose model the `ol` and `fetcher` VMs actually run.
set -uo pipefail
# shellcheck source=helpers.sh
. "$(dirname "$0")/helpers.sh"

cfg() { # cfg <role> [profile]
  local files=(-f "$REPO_ROOT/data-sources/docker-compose.yml" -f "$HS_DIR/compose.tunnel.yml")
  if [ -f "$HS_DIR/compose.$1.yml" ]; then files+=(-f "$HS_DIR/compose.$1.yml"); fi
  OL_DATA_HOST=/srv/ol-data TUNNEL_TOKEN=x COMPOSE_PROFILES="${2:-}" \
    docker compose --project-directory "$REPO_ROOT/data-sources" "${files[@]}" config --format json
}

t_build() {
  cfg ol | jq -e '.services.build.cpus == 6 and
    .services.build.command == ["python","-m","openlibrary.pipeline.build","--root","/data","--memory-limit","8GB"]' >/dev/null
}
t_api() {
  cfg ol | jq -e '.services.api.environment.OL_API_MEMORY_LIMIT == "6GB" and
    (.services.api.volumes[0].source == "/srv/ol-data") and (.services.api.volumes[0].read_only == true)' >/dev/null
}
t_pinned() {
  cfg ol tunnel | jq -e '.services.cloudflared.image | test("^cloudflare/cloudflared:[0-9]{4}\\.[0-9]+\\.[0-9]+$")' >/dev/null
}
t_off_by_default() { ! cfg ol | jq -e '.services | has("cloudflared")' >/dev/null; }
t_fetcher_untouched() {
  cfg fetcher | jq -e '.services.fetcher.mem_limit != null and (.services | has("cloudflared") | not)' >/dev/null
}

if ! command -v docker >/dev/null; then echo "SKIP  docker not installed"; exit 0; fi
check "build is capped at 6 CPUs and 8GB" t_build
check "api gets 6GB and a read-only /srv/ol-data" t_api
check "cloudflared is a pinned version" t_pinned
check "cloudflared is off until the tunnel profile is on" t_off_by_default
check "the fetcher service is unchanged" t_fetcher_untouched
finish
```

Run: `chmod +x deployment/home-server/test/compose_config_test.sh && deployment/home-server/test/compose_config_test.sh`
Expected: `all passed`. If `t_off_by_default` fails because this compose version lists profiled services in `config`, check `docker compose ... config --services` instead and adjust the helper, not the assertion. If `mem_limit` is reported under another key, read the JSON and use that key.

- [ ] **Step 4: Create the secrets file**

Add to `.sops.yaml`:

```yaml
  - path_regex: secrets/home-server\.env$
    age: age1dnc82r63zyqtqlet84l2naxhjrdcdrc3gaxp592y69u0pg0m2u3q9j02zf
```

Create `secrets/home-server.env` in plaintext first, never committed in that state. `PVE_HOST` is the address this session already SSHes to. Don't copy it from any committed file; there is none, by design.

```bash
PVE_HOST=<the host's IPv6 address>
OL_TUNNEL_TOKEN=
FETCHER_TUNNEL_TOKEN=
HC_OL_HEARTBEAT=
HC_OL_DEPLOY=
HC_OL_REFRESH=
HC_FETCHER_HEARTBEAT=
HC_FETCHER_DEPLOY=
```

Then encrypt in place and check:

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/production.txt
sops -e -i secrets/home-server.env
grep -c ENC secrets/home-server.env     # expect 8
sops -d secrets/home-server.env | head -1   # expect PVE_HOST=...
```

- [ ] **Step 5: Write `lib/common.sh`**

```bash
# deployment/home-server/lib/common.sh
# shellcheck shell=bash
# Logging, change tracking and the SSH plumbing every provision step uses.

HS_DIR="${HS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO_ROOT="${REPO_ROOT:-$(cd "$HS_DIR/../.." && pwd)}"
CHANGES=()
# Where provision keeps its own state on the host (tunnels flag, tracked ref).
HOST_STATE=/etc/the-greatest-home-server
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'provision: %s\n' "$*" >&2; exit 1; }
note_change() { CHANGES+=("$1"); log "changed: $1"; }

on_host() { ssh "${SSH_OPTS[@]}" "root@$PVE_HOST" "$@"; }

# host_file_matches <local> <remote>: true when the remote file has the same bytes.
host_file_matches() {
  local want have
  want="$(sha256sum <"$1" | cut -d' ' -f1)"
  have="$(on_host "sha256sum < '$2' 2>/dev/null | cut -d' ' -f1" || true)"
  [ "$want" = "$have" ]
}

# put_host <local> <remote> [mode]: write only when different; records a change.
# /etc/pve is the cluster filesystem: no chmod there, and no temp file + rename.
put_host() {
  local src=$1 dest=$2 mode=${3:-0644}
  host_file_matches "$src" "$dest" && return 0
  case "$dest" in
    /etc/pve/*) on_host "cat > '$dest'" <"$src" ;;
    *) on_host "mkdir -p '$(dirname "$dest")' && cat > '$dest.new' && chmod $mode '$dest.new' && mv '$dest.new' '$dest'" <"$src" ;;
  esac
  note_change "$dest"
}

# load_secrets: secrets/home-server.env -> exported variables. Parsed, not
# eval'ed: a value is data, never shell.
load_secrets() {
  local file="$REPO_ROOT/secrets/home-server.env" key value
  [ -f "$file" ] || die "missing $file"
  while IFS='=' read -r key value; do
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] && export "$key=$value"
  done < <(sops -d "$file") || die "could not decrypt $file (is SOPS_AGE_KEY_FILE set?)"
  [ -n "${PVE_HOST:-}" ] || die "PVE_HOST is not set in $file"
}

report_changes() {
  if [ "${#CHANGES[@]}" = 0 ]; then log "no changes"; else log "${#CHANGES[@]} change(s): ${CHANGES[*]}"; fi
}
```

- [ ] **Step 6: Write the cloud-init template**

```yaml
#cloud-config
# deployment/home-server/cloud-init/user-data.yaml.tmpl, rendered by
# provision (lib/vm.sh render_user_data) into a Proxmox snippet. First boot
# of the ${ROLE} VM; guest/first-boot.sh does the role-specific rest.
hostname: ${VM_NAME}
users:
  - name: debian
    groups: [sudo]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    ssh_authorized_keys:
      - ${SSH_PUBKEY}
ssh_pwauth: false
disable_root: true
package_update: true
package_upgrade: true
packages: [ca-certificates, curl, git, jq, qemu-guest-agent, unattended-upgrades]
write_files:
  - path: /etc/the-greatest/home-server.env
    permissions: "0600"
    encoding: b64
    content: ${ENV_B64}
  - path: /etc/apt/apt.conf.d/20auto-upgrades
    content: |
      APT::Periodic::Update-Package-Lists "1";
      APT::Periodic::Unattended-Upgrade "1";
  - path: /etc/apt/apt.conf.d/52unattended-upgrades-home-server
    content: |
      // reboot-if-required.timer reboots, and only when no data build is running.
      Unattended-Upgrade::Automatic-Reboot "false";
runcmd:
  - systemctl enable --now qemu-guest-agent
  - install -m 0755 -d /etc/apt/keyrings
  - curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  - echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian trixie stable" > /etc/apt/sources.list.d/docker.list
  - apt-get update -q
  - DEBIAN_FRONTEND=noninteractive apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  - systemctl enable --now docker
  - usermod -aG docker debian
  - git clone --depth 1 --branch ${REPO_REF} https://github.com/ssherman/the-greatest /opt/the-greatest
  - /opt/the-greatest/deployment/home-server/guest/first-boot.sh
```

- [ ] **Step 7: Write the render half of `lib/vm.sh`**

```bash
# deployment/home-server/lib/vm.sh
# shellcheck shell=bash
# The two VMs: their shape (spec §5), what they are told at first boot, and
# their creation, rebuild and settings.

DEBIAN_IMAGE=debian-13-genericcloud-amd64.qcow2
DEBIAN_IMAGE_DIR=https://cloud.debian.org/images/cloud/trixie/latest
SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-$HOME/.ssh/id_ed25519.pub}"

vm_spec() {
  case "$1" in
    ol)
      VMID=110 NAME=ol CORES=8 MEM=16384 OSDISK=32 DATADISK=300
      NET="virtio,bridge=vmbr0,firewall=1" IPCONFIG="ip=dhcp,ip6=auto" NAMESERVER="" STARTUP="order=1" ;;
    fetcher)
      VMID=120 NAME=fetcher CORES=4 MEM=4096 OSDISK=40 DATADISK=0
      NET="virtio,bridge=vmbr1,firewall=1" IPCONFIG="ip=10.20.0.10/24,gw=10.20.0.1"
      NAMESERVER="1.1.1.1 1.0.0.1" STARTUP="order=2" ;;
    *) die "unknown VM role '$1' (ol or fetcher)" ;;
  esac
}

# render_vm_env <role> <out>: the VM's /etc/the-greatest/home-server.env. Each
# VM gets only its own token and check URLs.
render_vm_env() {
  local role=$1 out=$2
  case "$role" in
    ol) printf '%s\n' "ROLE=ol" "REPO_REF=$REPO_REF" "TUNNELS_ENABLED=$TUNNELS_ENABLED" \
          "TUNNEL_TOKEN=${OL_TUNNEL_TOKEN:-}" "HC_HEARTBEAT=${HC_OL_HEARTBEAT:-}" \
          "HC_DEPLOY=${HC_OL_DEPLOY:-}" "HC_REFRESH=${HC_OL_REFRESH:-}" ;;
    fetcher) printf '%s\n' "ROLE=fetcher" "REPO_REF=$REPO_REF" "TUNNELS_ENABLED=$TUNNELS_ENABLED" \
          "TUNNEL_TOKEN=${FETCHER_TUNNEL_TOKEN:-}" "HC_HEARTBEAT=${HC_FETCHER_HEARTBEAT:-}" \
          "HC_DEPLOY=${HC_FETCHER_DEPLOY:-}" "HC_REFRESH=" ;;
    *) die "unknown VM role '$role'" ;;
  esac >"$out"
}

# render_user_data <role> <env-file> <out>
render_user_data() {
  vm_spec "$1"
  [ -f "$SSH_PUBKEY_FILE" ] || die "missing $SSH_PUBKEY_FILE"
  # shellcheck disable=SC2016 # envsubst takes the variable list literally
  VM_NAME="$NAME" ROLE="$1" SSH_PUBKEY="$(cat "$SSH_PUBKEY_FILE")" ENV_B64="$(base64 -w0 <"$2")" \
    REPO_REF="$REPO_REF" envsubst '${VM_NAME} ${ROLE} ${SSH_PUBKEY} ${ENV_B64} ${REPO_REF}' \
    <"$HS_DIR/cloud-init/user-data.yaml.tmpl" >"$3"
}
```

- [ ] **Step 8: Write `render_test.sh`**

```bash
#!/usr/bin/env bash
# deployment/home-server/test/render_test.sh
# What each VM is told at first boot.
set -uo pipefail
# shellcheck source=helpers.sh
. "$(dirname "$0")/helpers.sh"
# shellcheck source=../lib/common.sh
. "$HS_DIR/lib/common.sh"
# shellcheck source=../lib/vm.sh
. "$HS_DIR/lib/vm.sh"

new_sandbox
export REPO_REF=main TUNNELS_ENABLED=0 OL_TUNNEL_TOKEN=ol-token FETCHER_TUNNEL_TOKEN=fetcher-token
export HC_OL_HEARTBEAT=https://hc.test/ol-beat HC_OL_DEPLOY=https://hc.test/ol-deploy HC_OL_REFRESH=https://hc.test/ol-refresh
export HC_FETCHER_HEARTBEAT=https://hc.test/f-beat HC_FETCHER_DEPLOY=https://hc.test/f-deploy
echo "ssh-ed25519 AAAATEST test@example.com" >"$SANDBOX/key.pub"
export SSH_PUBKEY_FILE="$SANDBOX/key.pub"

for role in ol fetcher; do
  render_vm_env "$role" "$SANDBOX/$role.env"
  render_user_data "$role" "$SANDBOX/$role.env" "$SANDBOX/$role.yaml"
done
env_from_yaml() { # decode the env file a rendered user-data carries
  ruby -ryaml -rbase64 -e 'y = YAML.load_file(ARGV[0]); f = y["write_files"].find { |w| w["path"] == "/etc/the-greatest/home-server.env" }; print Base64.decode64(f["content"])' "$1"
}

t_yaml() { for r in ol fetcher; do ruby -ryaml -e 'YAML.load_file(ARGV[0])' "$SANDBOX/$r.yaml" || return 1; done; }
t_first_line() { [ "$(head -1 "$SANDBOX/ol.yaml")" = "#cloud-config" ]; }
t_no_leftovers() { ! grep -q '\${' "$SANDBOX/ol.yaml" "$SANDBOX/fetcher.yaml"; }
t_ol_env() {
  env_from_yaml "$SANDBOX/ol.yaml" | grep -qx 'ROLE=ol' &&
    env_from_yaml "$SANDBOX/ol.yaml" | grep -qx 'TUNNEL_TOKEN=ol-token' &&
    env_from_yaml "$SANDBOX/ol.yaml" | grep -qx 'HC_REFRESH=https://hc.test/ol-refresh'
}
t_fetcher_isolation() {
  local env; env="$(env_from_yaml "$SANDBOX/fetcher.yaml")"
  grep -qx 'TUNNEL_TOKEN=fetcher-token' <<<"$env" && ! grep -q 'ol-token\|ol-beat\|ol-refresh' <<<"$env"
}
t_key() { grep -q 'ssh-ed25519 AAAATEST' "$SANDBOX/ol.yaml"; }
t_ref() { grep -q 'clone --depth 1 --branch main ' "$SANDBOX/ol.yaml"; }
t_blank_secrets() {
  (unset OL_TUNNEL_TOKEN HC_OL_HEARTBEAT; render_vm_env ol "$SANDBOX/blank.env") &&
    grep -qx 'TUNNEL_TOKEN=' "$SANDBOX/blank.env"
}

check "both user-data files are valid YAML" t_yaml
check "user-data starts with #cloud-config" t_first_line
check "no template variable is left unrendered" t_no_leftovers
check "ol gets its role, token and refresh check" t_ol_env
check "fetcher holds nothing of ol's" t_fetcher_isolation
check "the dev key is authorized" t_key
check "the VM clones the tracked ref" t_ref
check "unset secrets render as blanks, not errors" t_blank_secrets
finish
```

- [ ] **Step 9: Run all shell tests**

Run: `chmod +x deployment/home-server/test/render_test.sh && deployment/home-server/test/run.sh`
Expected: shellcheck clean (it now covers `lib/common.sh` and `lib/vm.sh`), every file `all passed`.

- [ ] **Step 10: Commit**

```bash
git add .sops.yaml secrets/home-server.env deployment/home-server/compose.*.yml deployment/home-server/cloud-init deployment/home-server/lib deployment/home-server/test
git commit -m "home-server: compose overrides, cloud-init template, encrypted secrets"
```

Before committing, confirm the address isn't in the diff in clear: `git diff --cached | grep -c 2605` must print `0`.

---

### Task 5: `provision` and the host's packages (runs against the real box)

**Files:**
- Create: `deployment/home-server/provision`, `deployment/home-server/lib/host.sh`
- Create: `deployment/home-server/host/apt/{proxmox.sources,20auto-upgrades,52unattended-upgrades-home-server}`, `deployment/home-server/host/sbin/confirm-or-revert`

**Interfaces:**
- Produces: `converge_host_packages`, plus the `confirm-or-revert` helper installed on the host (`arm <name> <seconds> <cmd>`, `confirm <name>`) for Tasks 6–7.
- Produces: `provision` CLI: no args = converge; `--rebuild ol|fetcher`; `--enable-tunnels`; `--verify [--external-from user@host] [--recovery]`; `--ref <ref>` (stored on the host, default `main`).

- [ ] **Step 1: Write the host files**

`host/apt/proxmox.sources`:
```
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
```

`host/apt/20auto-upgrades`:
```
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
```

`host/apt/52unattended-upgrades-home-server`:
```
// Debian security updates only (the package default). Proxmox's own packages
// are upgraded by provision, and the host never reboots itself (spec §4).
Unattended-Upgrade::Automatic-Reboot "false";
```

`host/sbin/confirm-or-revert`:
```bash
#!/bin/bash
# Installed by deployment/home-server/provision. A change that could cut off
# SSH is armed with a revert first; provision confirms only once it can
# reconnect, so a lockout undoes itself.
#   confirm-or-revert arm <name> <seconds> <revert shell command>
#   confirm-or-revert confirm <name>
set -euo pipefail
case "${1:-}" in
  arm)
    systemctl stop "revert-$2.timer" 2>/dev/null || true
    systemd-run --quiet --collect --unit="revert-$2" --on-active="$3" \
      --timer-property=AccuracySec=1s /bin/sh -c "$4"
    ;;
  confirm) systemctl stop "revert-$2.timer" ;;
  *) echo "usage: confirm-or-revert arm <name> <seconds> <cmd> | confirm <name>" >&2; exit 2 ;;
esac
```

- [ ] **Step 2: Write `lib/host.sh` (packages part) and `provision`**

```bash
# deployment/home-server/lib/host.sh
# shellcheck shell=bash
# The Proxmox host (spec §4): packages, network, firewall.

converge_host_packages() {
  put_host "$HS_DIR/host/sbin/confirm-or-revert" /usr/local/sbin/confirm-or-revert 0755

  # The enterprise repos need a subscription; with none, apt update fails.
  local f
  for f in pve-enterprise ceph; do
    if on_host "test -f /etc/apt/sources.list.d/$f.sources && ! grep -q '^Enabled: no' /etc/apt/sources.list.d/$f.sources"; then
      on_host "echo 'Enabled: no' >> /etc/apt/sources.list.d/$f.sources"
      note_change "disabled $f.sources"
    fi
  done
  put_host "$HS_DIR/host/apt/proxmox.sources" /etc/apt/sources.list.d/proxmox.sources
  put_host "$HS_DIR/host/apt/20auto-upgrades" /etc/apt/apt.conf.d/20auto-upgrades
  put_host "$HS_DIR/host/apt/52unattended-upgrades-home-server" /etc/apt/apt.conf.d/52unattended-upgrades-home-server

  on_host "apt-get update -q >/dev/null" || die "apt-get update failed on the host"
  if ! on_host "dpkg -s jq unattended-upgrades >/dev/null 2>&1"; then
    on_host "DEBIAN_FRONTEND=noninteractive apt-get install -y -q jq unattended-upgrades >/dev/null"
    note_change "installed jq unattended-upgrades"
  fi
  local pending
  pending="$(on_host "apt-get -s full-upgrade | grep -c '^Inst' || true")"
  if [ "$pending" != 0 ]; then
    log "upgrading $pending host package(s)"
    on_host "DEBIAN_FRONTEND=noninteractive apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade >/dev/null"
    UPGRADED="$pending"   # reported, but not a "change" for the idempotence check
  fi

  # Nothing here uses NFS.
  if on_host "systemctl is-enabled --quiet rpcbind.socket || systemctl is-active --quiet rpcbind"; then
    on_host "systemctl disable --now rpcbind.socket rpcbind.service >/dev/null 2>&1"
    note_change "disabled rpcbind"
  fi

  # Custom cloud-init user-data lives in snippets on `local`.
  if ! on_host "pvesm config local 2>/dev/null | grep -q '^\s*content .*snippets'"; then
    on_host "pvesm set local --content iso,vztmpl,backup,import,snippets"
    note_change "snippets on local storage"
  fi
  on_host "mkdir -p $HOST_STATE"

  local running newest
  running="$(on_host "uname -r")"
  newest="$(on_host "ls /boot/vmlinuz-* | sed 's|/boot/vmlinuz-||' | sort -V | tail -1")"
  if [ "$running" != "$newest" ]; then
    log "NOTE: kernel $newest is installed but $running is running; the host never reboots itself"
  fi
}
```

`pvesm config` may not exist as a subcommand. If it errors, read `/etc/pve/storage.cfg` instead: `awk '/^dir: local$/{f=1;next} /^[a-z]+:/{f=0} f && /content/' /etc/pve/storage.cfg | grep -q snippets`. Use whichever works on the box and note it in the commit.

```bash
#!/usr/bin/env bash
# deployment/home-server/provision
# Converges the Proxmox home server from this repo (docs/features/home-server.md).
#   provision                       host, any missing VM, VM env and units
#   provision --rebuild ol|fetcher  replace that VM's OS disk (data disk kept)
#   provision --enable-tunnels      start cloudflared on both VMs, once Access is in place
#   provision --verify [--external-from user@host] [--recovery]
#   provision --ref <git ref>       the ref the VMs track (stored on the host; default main)
set -euo pipefail
HS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HS_DIR/../.." && pwd)"
# shellcheck source=lib/common.sh
. "$HS_DIR/lib/common.sh"
# shellcheck source=lib/host.sh
. "$HS_DIR/lib/host.sh"
# shellcheck source=lib/vm.sh
. "$HS_DIR/lib/vm.sh"
# shellcheck source=lib/verify.sh
. "$HS_DIR/lib/verify.sh"

mode=converge rebuild_role="" EXTERNAL_FROM="" RECOVERY=0 ref_arg="" UPGRADED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --rebuild) mode=rebuild; rebuild_role="${2:?--rebuild needs ol or fetcher}"; shift 2 ;;
    --enable-tunnels) mode=enable-tunnels; shift ;;
    --verify) mode=verify; shift ;;
    --external-from) EXTERNAL_FROM="${2:?}"; shift 2 ;;
    --recovery) RECOVERY=1; shift ;;
    --ref) ref_arg="${2:?}"; shift 2 ;;
    -h | --help) sed -n '2,8p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

load_secrets
on_host true || die "cannot reach root@$PVE_HOST over SSH"
load_host_state "$ref_arg"

case "$mode" in
  converge)
    converge_host_packages
    converge_host_network
    converge_host_firewall
    for role in fetcher ol; do ensure_vm "$role"; done
    ;;
  rebuild) rebuild_vm "$rebuild_role" ;;
  enable-tunnels) enable_tunnels ;;
  verify) verify_all ;;
esac
report_changes
if [ "$UPGRADED" != 0 ]; then log "upgraded $UPGRADED host package(s)"; fi
```

Add to `lib/common.sh`:

```bash
# load_host_state [ref]: the ref the VMs track and whether tunnels are on, both
# kept on the host so any machine running provision sees the same answer.
load_host_state() {
  on_host "mkdir -p $HOST_STATE"
  if [ -n "${1:-}" ]; then
    on_host "printf '%s\n' '$1' > $HOST_STATE/repo-ref"
  fi
  REPO_REF="$(on_host "cat $HOST_STATE/repo-ref 2>/dev/null || echo main")"
  TUNNELS_ENABLED=0
  if on_host "test -f $HOST_STATE/tunnels-enabled"; then TUNNELS_ENABLED=1; fi
  export REPO_REF TUNNELS_ENABLED
}
```

For this task only, create `lib/verify.sh` with `verify_all() { die "verify is added in Task 9"; }` and stub `converge_host_network() { :; }`, `converge_host_firewall() { :; }` at the end of `lib/host.sh`, and `ensure_vm() { :; }` in `lib/vm.sh`. Tasks 6–9 replace each stub.

- [ ] **Step 3: Run the shell tests**

Run: `chmod +x deployment/home-server/provision deployment/home-server/host/sbin/confirm-or-revert && deployment/home-server/test/run.sh`
Expected: shellcheck clean, all tests pass.

- [ ] **Step 4: Run it against the box**

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/production.txt
deployment/home-server/provision
```

Expected: changes for the confirm-or-revert helper, two disabled `.sources` files, three apt files, jq/unattended-upgrades, rpcbind and snippets. Then `upgraded N host package(s)`, likely a large N on first run, and possibly the kernel NOTE.

- [ ] **Step 5: Run it again: the idempotence check for this slice**

Run: `deployment/home-server/provision`
Expected: `no changes`. Any change listed is a bug in its check; fix it before going on.

- [ ] **Step 6: Confirm on the host**

Run: `ssh root@"$PVE_HOST" 'apt-get update 2>&1 | grep -ci "401\|error"; ss -ltn "sport = :111" | tail -n +2 | wc -l; pvesm status | grep local'`
Expected: `0`, `0`, and `local` still active.

- [ ] **Step 7: Commit**

```bash
git add deployment/home-server
git commit -m "home-server: provision entry point and host package convergence"
```

---

### Task 6: Host network: IPv4 on vmbr0 and the private vmbr1 (real box)

**Files:**
- Create: `deployment/home-server/host/network/vmbr1`
- Modify: `deployment/home-server/lib/host.sh` (replace the `converge_host_network` stub)

**Interfaces:**
- Consumes: `confirm-or-revert` (Task 5).
- Produces: vmbr0 with IPv4 by DHCP; `vmbr1` 10.20.0.1/24 NAT'd out vmbr0; `net.ipv4.ip_forward=1`, `net.ipv6.conf.all.forwarding=0`. Task 7 reads `LAN_IPV4_CIDR`/`LAN_IPV6_PREFIX`, which `converge_host_network` exports.

- [ ] **Step 1: Write `host/network/vmbr1`**

```
# Installed by deployment/home-server/provision. The fetcher VM's private
# network (spec §4): IPv4 only, NAT'd out vmbr0. What it may reach is decided
# by /etc/pve/firewall/120.fw, enforced on this host.
auto vmbr1
iface vmbr1 inet static
	address 10.20.0.1/24
	bridge-ports none
	bridge-stp off
	bridge-fd 0
	post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
	post-up   iptables -t nat -A POSTROUTING -s 10.20.0.0/24 -o vmbr0 -j MASQUERADE
	post-down iptables -t nat -D POSTROUTING -s 10.20.0.0/24 -o vmbr0 -j MASQUERADE
	# Required with the Proxmox firewall on a NAT'd guest's NIC (Proxmox admin guide, "Masquerading").
	post-up   iptables -t raw -I PREROUTING -i fwbr+ -j CT --zone 1
	post-down iptables -t raw -D PREROUTING -i fwbr+ -j CT --zone 1
```

Use real tab characters for indentation. That's the style the installer used in `/etc/network/interfaces`.

- [ ] **Step 2: Implement `converge_host_network`**

```bash
# network_change <description> <function>: run a change that could cut this
# session off. A revert is armed first; only a successful reconnect confirms it.
network_change() {
  local what=$1 mutate=$2
  on_host "cp -a /etc/network/interfaces /root/interfaces.provision-bak &&
    rm -rf /root/interfaces.d.provision-bak && cp -a /etc/network/interfaces.d /root/interfaces.d.provision-bak"
  on_host "confirm-or-revert arm network 120 'cp -a /root/interfaces.provision-bak /etc/network/interfaces;
    rm -rf /etc/network/interfaces.d; cp -a /root/interfaces.d.provision-bak /etc/network/interfaces.d; ifreload -a'"
  "$mutate"
  # Detached: ifreload may drop this very connection.
  on_host "systemd-run --quiet --collect --unit=provision-ifreload ifreload -a" || true
  sleep 15
  if on_host true; then
    on_host "confirm-or-revert confirm network"
    note_change "$what"
  else
    log "lost the host after: $what; waiting for the automatic revert"
    sleep 130
    if on_host true; then die "'$what' cut off SSH and was reverted"; fi
    die "host unreachable even after the revert; use the console"
  fi
}

add_vmbr0_dhcp() { on_host "sed -i '/^iface vmbr0 inet6 /i iface vmbr0 inet dhcp\n' /etc/network/interfaces"; }
write_vmbr1() { on_host "cat > /etc/network/interfaces.d/vmbr1" <"$HS_DIR/host/network/vmbr1"; }

converge_host_network() {
  # GitHub and ghcr.io have no IPv6, so the host and guests need IPv4 (spec §1).
  if ! on_host "grep -q '^iface vmbr0 inet ' /etc/network/interfaces"; then
    network_change "vmbr0 gains IPv4 by DHCP" add_vmbr0_dhcp
  fi
  if ! host_file_matches "$HS_DIR/host/network/vmbr1" /etc/network/interfaces.d/vmbr1; then
    network_change "vmbr1 private NAT bridge" write_vmbr1
  fi

  LAN_IPV4_CIDR="$(on_host "ip -4 -o route show dev vmbr0 proto kernel scope link | awk '{print \$1}' | head -1")"
  LAN_IPV6_PREFIX="$(on_host "ip -6 -o route show dev vmbr0 proto kernel | awk '\$1 !~ /^fe80/ {print \$1}' | head -1")"
  [ -n "$LAN_IPV4_CIDR" ] || die "vmbr0 has no IPv4 route; did the router hand out a DHCP lease?"
  [ -n "$LAN_IPV6_PREFIX" ] || die "vmbr0 has no IPv6 prefix route"
  export LAN_IPV4_CIDR LAN_IPV6_PREFIX

  [ "$(on_host "sysctl -n net.ipv4.ip_forward")" = 1 ] || die "ip_forward is off; vmbr1's post-up did not run"
  [ "$(on_host "sysctl -n net.ipv6.conf.all.forwarding")" = 0 ] || die "IPv6 forwarding is on; the fetcher must have no IPv6 path"
}
```

The `sed` in `add_vmbr0_dhcp` inserts before the existing `iface vmbr0 inet6 static` stanza. The resulting file has `iface vmbr0 inet dhcp` with no attributes, followed by the inet6 stanza carrying `bridge-ports`. ifupdown2 merges stanzas for the same interface.

- [ ] **Step 3: Rehearse the revert before trusting it**

Prove the lockout path works before a real change depends on it:

```bash
ssh root@"$PVE_HOST" 'confirm-or-revert arm rehearsal 20 "touch /root/revert-fired"; sleep 25; ls /root/revert-fired && rm /root/revert-fired'
ssh root@"$PVE_HOST" 'confirm-or-revert arm rehearsal 20 "touch /root/revert-fired"; confirm-or-revert confirm rehearsal; sleep 25; ls /root/revert-fired 2>&1'
```

Expected: the first prints `/root/revert-fired`. The second prints `No such file or directory`.

- [ ] **Step 4: Run it against the box**

Run: `deployment/home-server/provision`
Expected: `changed: vmbr0 gains IPv4 by DHCP`, `changed: vmbr1 private NAT bridge`, no die.

- [ ] **Step 5: Check the result and idempotence**

```bash
ssh root@"$PVE_HOST" 'ip -br addr show vmbr0; ip -br addr show vmbr1; iptables -t nat -S POSTROUTING | grep 10.20; curl -4 -sS -o /dev/null -w "%{http_code}\n" https://github.com'
deployment/home-server/provision
```

Expected: vmbr0 shows a `192.168.1.x` address alongside its IPv6; vmbr1 `10.20.0.1/24`; one MASQUERADE rule; `200`; second run `no changes`.

- [ ] **Step 6: Commit**

```bash
git add deployment/home-server
git commit -m "home-server: host IPv4 by DHCP and the fetcher's private NAT bridge"
```

---

### Task 7: Host and VM firewalls (real box)

**Files:**
- Create: `deployment/home-server/host/firewall/{cluster.fw.tmpl,host.fw,110.fw,120.fw}`
- Modify: `deployment/home-server/lib/host.sh` (replace the `converge_host_firewall` stub)

**Interfaces:**
- Consumes: `LAN_IPV4_CIDR`, `LAN_IPV6_PREFIX` (Task 6).
- Produces: datacenter firewall on (input DROP), 22/8006 from LAN only, VM 110 and 120 rule files (in effect once the VMs exist in Task 8).

- [ ] **Step 1: Write the firewall files**

`host/firewall/cluster.fw.tmpl`:
```
# Rendered by deployment/home-server/provision; the LAN ranges are read off
# the host at provision time, never committed (spec §4).
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: ACCEPT

[IPSET lan] # the house LAN: IPv4 and the host's current IPv6 /64
${LAN_IPV4_CIDR}
${LAN_IPV6_PREFIX}

[IPSET private] # destinations the fetcher may never reach
0.0.0.0/8
10.0.0.0/8
100.64.0.0/10
127.0.0.0/8
169.254.0.0/16
172.16.0.0/12
192.168.0.0/16
224.0.0.0/4
240.0.0.0/4
```

`host/firewall/host.fw`:
```
# Installed by deployment/home-server/provision. SSH and the web UI from the
# house LAN only. Proxmox also keeps its own management rule for the host's
# local network, which is what stops a mistake here from locking out SSH.
[OPTIONS]
enable: 1

[RULES]
IN ACCEPT -source +lan -p tcp -dport 22 -log nolog
IN ACCEPT -source +lan -p tcp -dport 8006 -log nolog
```

`host/firewall/110.fw`:
```
# VM 110 `ol`, on the LAN. Nothing listens beyond SSH: its services publish on
# loopback and leave through cloudflared.
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: ACCEPT
dhcp: 1
ndp: 1
radv: 0

[RULES]
IN ACCEPT -source +lan -p tcp -dport 22 -log nolog
```

`host/firewall/120.fw`:
```
# VM 120 `fetcher`, on vmbr1. Enforced on the host, so root inside the VM
# cannot change it (spec §4): no private destination, no spoofed source.
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: ACCEPT
dhcp: 0
ndp: 0
radv: 0
ipfilter: 1

[IPSET ipfilter-net0]
10.20.0.10

[RULES]
OUT DROP -dest +private -log nolog
IN ACCEPT -source 10.20.0.1 -p tcp -dport 22 -log nolog
```

- [ ] **Step 2: Implement `converge_host_firewall`**

```bash
converge_host_firewall() {
  local rendered
  rendered="$(mktemp -d)"
  # shellcheck disable=SC2016 # envsubst takes the variable list literally
  LAN_IPV4_CIDR="$LAN_IPV4_CIDR" LAN_IPV6_PREFIX="$LAN_IPV6_PREFIX" \
    envsubst '${LAN_IPV4_CIDR} ${LAN_IPV6_PREFIX}' <"$HS_DIR/host/firewall/cluster.fw.tmpl" >"$rendered/cluster.fw"
  cp "$HS_DIR/host/firewall/host.fw" "$HS_DIR/host/firewall/110.fw" "$HS_DIR/host/firewall/120.fw" "$rendered/"

  local pairs=("cluster.fw:/etc/pve/firewall/cluster.fw" "host.fw:/etc/pve/nodes/pve/host.fw"
    "110.fw:/etc/pve/firewall/110.fw" "120.fw:/etc/pve/firewall/120.fw")
  local pair stale=()
  for pair in "${pairs[@]}"; do
    host_file_matches "$rendered/${pair%%:*}" "${pair#*:}" || stale+=("$pair")
  done
  if [ "${#stale[@]}" = 0 ]; then rm -rf "$rendered"; return 0; fi

  # Stopping pve-firewall drops every rule it installed: the safe state if a
  # rule here cuts SSH off.
  on_host "confirm-or-revert arm firewall 120 'pve-firewall stop'"
  for pair in "${stale[@]}"; do put_host "$rendered/${pair%%:*}" "${pair#*:}"; done
  rm -rf "$rendered"
  on_host "pve-firewall compile >/dev/null" || die "pve-firewall rejected the rules (compile failed)"
  on_host "systemctl restart pve-firewall"
  sleep 15
  if on_host "pve-firewall status | grep -q 'enabled/running'"; then
    on_host "confirm-or-revert confirm firewall"
  else
    die "firewall did not come up; the armed revert stops it in under two minutes"
  fi
}
```

The node directory is `/etc/pve/nodes/pve/` because the node is named `pve` (spec §1). If `pve-firewall status` prints something other than `enabled/running`, read its output and match the real string. Don't weaken the check.

- [ ] **Step 3: Run it against the box**

Run: `deployment/home-server/provision`
Expected: four firewall files changed; no die.

- [ ] **Step 4: Check access is intact and port 111/3128 are filtered**

```bash
ssh root@"$PVE_HOST" true && echo ssh-ok
curl -sk -o /dev/null -w '%{http_code}\n' "https://[$PVE_HOST]:8006/"
ssh root@"$PVE_HOST" 'pve-firewall status; iptables-save | grep -c PVEFW'
deployment/home-server/provision   # expect: no changes
```

Expected: `ssh-ok`, `200`, `Status: enabled/running`, a nonzero rule count, `no changes`. Testing from outside the house waits until Task 12.

- [ ] **Step 5: Commit**

```bash
git add deployment/home-server
git commit -m "home-server: datacenter, host and per-VM firewall rules"
```

---

### Task 8: The VMs (real box)

**Files:**
- Modify: `deployment/home-server/lib/vm.sh` (replace the `ensure_vm` stub; add the rest)

**Interfaces:**
- Consumes: render functions (Task 4), `put_host`, `HOST_STATE`, `REPO_REF`, `TUNNELS_ENABLED`.
- Produces: `vm_ssh <role> <cmd>`, `vm_ip <role>`, `ensure_vm <role>`, `rebuild_vm <role>`, `enable_tunnels`. Task 9 uses `vm_ssh` and `vm_ip`.

- [ ] **Step 1: Ask Shane to push the branch**

The VMs clone the repo from GitHub, and until merge the guest scripts exist only on this branch. Ask him: *"The VMs clone the repo from GitHub, so they need this branch pushed (`worktree-home-server`). It contains no addresses or tokens; I checked `git log -p | grep 2605` is empty. OK to push?"* After a yes:

```bash
git log -p | grep -c 2605    # must print 0
git push -u origin worktree-home-server
```

- [ ] **Step 2: Implement the rest of `lib/vm.sh`**

```bash
VM_SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

# vm_ip <role>: fetcher's is fixed; ol's comes from the guest agent.
vm_ip() {
  vm_spec "$1"
  if [ "$1" = fetcher ]; then echo 10.20.0.10; return; fi
  on_host "qm guest cmd $VMID network-get-interfaces 2>/dev/null" |
    jq -r '[.[] | select(.name != "lo") | ."ip-addresses"[]? | select(."ip-address-type" == "ipv4") | ."ip-address"] | first // empty'
}

# vm_ssh <role> <cmd>: as `debian`, jumping through the host. Host keys are
# not pinned: the VMs are only reachable through the (pinned) host, and a
# rebuilt VM gets new keys by design.
vm_ssh() {
  local role=$1 ip; shift
  ip="$(vm_ip "$role")"
  [ -n "$ip" ] || die "no IPv4 address for $role yet"
  ssh "${VM_SSH_OPTS[@]}" -o ProxyCommand="ssh ${SSH_OPTS[*]} -W %h:%p root@$PVE_HOST" "debian@$ip" "$@"
}

# ensure_image [refresh]: the Debian cloud image, checksum-verified. A rebuild
# refreshes it; otherwise an existing copy is reused.
ensure_image() {
  local fetch="curl -fsSLO $DEBIAN_IMAGE_DIR/$DEBIAN_IMAGE && curl -fsSLO $DEBIAN_IMAGE_DIR/SHA512SUMS && sha512sum --ignore-missing -c SHA512SUMS"
  if [ "${1:-}" = refresh ]; then
    on_host "mkdir -p /var/lib/vz/import && cd /var/lib/vz/import && $fetch" || die "could not fetch and verify $DEBIAN_IMAGE"
  else
    on_host "mkdir -p /var/lib/vz/import && cd /var/lib/vz/import && { [ -f $DEBIAN_IMAGE ] || { $fetch; }; }" ||
      die "could not fetch and verify $DEBIAN_IMAGE"
  fi
}

write_snippet() { # write_snippet <role>; leaves the rendered env in $ENV_RENDERED
  local tmp; tmp="$(mktemp -d)"
  render_vm_env "$1" "$tmp/env"
  render_user_data "$1" "$tmp/env" "$tmp/user-data"
  put_host "$tmp/user-data" "/var/lib/vz/snippets/$NAME-user-data.yaml" 0600
  ENV_RENDERED="$tmp/env"
}

attach_os_disk() {
  on_host "qm set $VMID --scsi0 local-lvm:0,import-from=local:import/$DEBIAN_IMAGE,discard=on,ssd=1,iothread=1 --boot order=scsi0 >/dev/null &&
    qm disk resize $VMID scsi0 ${OSDISK}G"
}

create_vm() {
  log "creating VM $VMID ($NAME)"
  on_host "qm create $VMID --name $NAME --machine q35 --cpu host --cores $CORES --memory $MEM --balloon 0 \
    --scsihw virtio-scsi-single --net0 $NET --agent enabled=1 --onboot 1 --startup $STARTUP \
    --ostype l26 --serial0 socket --vga serial0 --ide2 local-lvm:cloudinit \
    --ipconfig0 $IPCONFIG --cicustom user=local:snippets/$NAME-user-data.yaml" || die "qm create $VMID failed"
  if [ -n "$NAMESERVER" ]; then on_host "qm set $VMID --nameserver '$NAMESERVER' >/dev/null"; fi
  attach_os_disk
  if [ "$DATADISK" != 0 ]; then
    on_host "qm set $VMID --scsi1 local-lvm:$DATADISK,discard=on,ssd=1,iothread=1 >/dev/null"
  fi
  on_host "qm start $VMID"
  note_change "created VM $VMID ($NAME)"
}

wait_for_first_boot() { # wait_for_first_boot <role>
  local i
  for i in $(seq 1 60); do vm_ssh "$1" true 2>/dev/null && break; sleep 10; done
  vm_ssh "$1" true || die "$1 never answered SSH"
  log "waiting for $1's cloud-init (the first image build takes several minutes)"
  vm_ssh "$1" "cloud-init status --wait >/dev/null; cloud-init status --long" | tee /dev/stderr | grep -q 'status: done' ||
    die "$1's cloud-init did not finish cleanly; read: vm_ssh $1 'sudo cat /var/log/cloud-init-output.log'"
}

converge_vm_settings() {
  local cfg drift=0
  cfg="$(on_host "qm config $VMID")"
  grep -qx "cores: $CORES" <<<"$cfg" || drift=1
  grep -qx "memory: $MEM" <<<"$cfg" || drift=1
  grep -qx "balloon: 0" <<<"$cfg" || drift=1
  grep -qx "onboot: 1" <<<"$cfg" || drift=1
  grep -qx "startup: $STARTUP" <<<"$cfg" || drift=1
  if [ "$drift" = 1 ]; then
    on_host "qm set $VMID --cores $CORES --memory $MEM --balloon 0 --onboot 1 --startup $STARTUP >/dev/null"
    note_change "VM $VMID settings (takes effect at its next restart)"
  fi
}

push_vm_env() { # push_vm_env <role>: the env file, then a forced deploy if it changed
  local want have
  want="$(sha256sum <"$ENV_RENDERED" | cut -d' ' -f1)"
  have="$(vm_ssh "$1" "sudo sha256sum /etc/the-greatest/home-server.env | cut -d' ' -f1")"
  [ "$want" = "$have" ] && return 0
  vm_ssh "$1" "sudo install -m 0600 /dev/stdin /etc/the-greatest/home-server.env" <"$ENV_RENDERED"
  vm_ssh "$1" "sudo touch /var/lib/the-greatest/force-deploy && sudo systemctl start the-greatest-deploy.service" ||
    log "deploy on $1 failed or was deferred; it retries every 15 minutes"
  note_change "$1 env"
}

ensure_vm() {
  vm_spec "$1"
  ensure_image
  write_snippet "$1"
  if ! on_host "qm status $VMID >/dev/null 2>&1"; then
    create_vm
    wait_for_first_boot "$1"
    return
  fi
  converge_vm_settings
  if ! on_host "qm status $VMID | grep -q running"; then on_host "qm start $VMID"; note_change "started VM $VMID"; fi
  push_vm_env "$1"
}

rebuild_vm() { # replace only the OS disk; the data disk is never touched (spec §5)
  vm_spec "$1"
  on_host "qm status $VMID >/dev/null 2>&1" || die "VM $VMID does not exist; run provision without --rebuild"
  ensure_image refresh
  write_snippet "$1"
  on_host "qm shutdown $VMID --timeout 120 || qm stop $VMID"
  on_host "qm disk unlink $VMID --idlist scsi0 --force"
  attach_os_disk
  on_host "qm cloudinit update $VMID && qm start $VMID"
  note_change "rebuilt VM $VMID ($NAME)"
  wait_for_first_boot "$1"
}

enable_tunnels() {
  [ -n "${OL_TUNNEL_TOKEN:-}" ] && [ -n "${FETCHER_TUNNEL_TOKEN:-}" ] ||
    die "both tunnel tokens must be set in secrets/home-server.env first (sops secrets/home-server.env)"
  on_host "touch $HOST_STATE/tunnels-enabled"
  TUNNELS_ENABLED=1
  local role
  for role in fetcher ol; do vm_spec "$role"; write_snippet "$role"; push_vm_env "$role"; done
}
```

Remove the `ensure_vm() { :; }` stub.


- [ ] **Step 3: Shell tests still pass**

Run: `deployment/home-server/test/run.sh`
Expected: shellcheck clean, all pass.

- [ ] **Step 4: Point the VMs at the branch and create them**

Run: `deployment/home-server/provision --ref worktree-home-server`
Expected: the image is downloaded and verified (`OK`), `created VM 120 (fetcher)`, and fetcher's cloud-init finishes with `status: done`. The fetcher image build takes roughly 10–20 minutes. Then the same for VM 110 (`ol`), with `status: done`.

- [ ] **Step 5: Check both VMs**

```bash
ssh root@"$PVE_HOST" 'qm list; qm config 110 | grep -E "^(cores|memory|balloon|onboot|startup|scsi|net0)"; qm config 120 | grep -E "^(cores|memory|net0|onboot)"'
source deployment/home-server/lib/common.sh; source deployment/home-server/lib/vm.sh; load_secrets
vm_ssh fetcher 'curl -fsS 127.0.0.1:8081/health | jq .camoufox_version; systemctl list-timers --no-pager | grep -c the-greatest'
vm_ssh ol 'mountpoint /srv/ol-data; systemctl list-timers --no-pager | grep -E "ol-refresh|the-greatest"; systemctl status ol-refresh --no-pager | head -5'
```

Expected: both VMs running with the sizes in Global Constraints. The fetcher health check answers and shows 2 timers. `ol` has `/srv/ol-data is a mountpoint` and its timers. `ol-refresh` is running, since the first build starts at boot, or has finished with a reason in its log.

- [ ] **Step 6: Idempotence**

Run: `deployment/home-server/provision`
Expected: `no changes`.

- [ ] **Step 7: Commit**

```bash
git add deployment/home-server
git commit -m "home-server: create, rebuild and configure the ol and fetcher VMs"
git push
```

---

### Task 9: `provision --verify` (real box)

**Files:**
- Modify: `deployment/home-server/lib/verify.sh` (replace the stub)

**Interfaces:**
- Consumes: `on_host`, `vm_ssh`, `vm_ip`, `vm_spec`, the converge functions.
- Produces: `verify_all`. It exits non-zero if any check fails, printing `PASS`/`FAIL` lines.

- [ ] **Step 1: Implement**

```bash
# deployment/home-server/lib/verify.sh
# shellcheck shell=bash
# provision --verify: everything about the box that can be checked from here.
VERIFY_FAILURES=0
ok() { echo "PASS  $1"; }
bad() { echo "FAIL  $1${2:+ -- $2}"; VERIFY_FAILURES=$((VERIFY_FAILURES + 1)); }
expect() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }

tcp_from_vm() { # tcp_from_vm <role> <host> <port>: can the VM open a TCP connection?
  vm_ssh "$1" "timeout 5 bash -c '</dev/tcp/$2/$3'" >/dev/null 2>&1
}
tcp_from_fetcher_container() {
  vm_ssh fetcher "docker exec the-greatest-fetcher-1 python -c 'import socket,sys; socket.create_connection((sys.argv[1], int(sys.argv[2])), 5)' $1 $2" >/dev/null 2>&1
}

verify_host() {
  expect "host: apt update is clean" on_host "! apt-get update -q 2>&1 | grep -qiE '^(E|Err):|401'"
  expect "host: enterprise repos disabled" on_host "grep -q '^Enabled: no' /etc/apt/sources.list.d/pve-enterprise.sources"
  expect "host: unattended-upgrades installed" on_host "dpkg -s unattended-upgrades"
  expect "host: nothing listens on 111" on_host "! ss -ltnH 'sport = :111' | grep -q ."
  expect "host: firewall running" on_host "pve-firewall status | grep -q 'enabled/running'"
  expect "host: IPv4 forwarding on" on_host "[ \$(sysctl -n net.ipv4.ip_forward) = 1 ]"
  expect "host: IPv6 forwarding off" on_host "[ \$(sysctl -n net.ipv6.conf.all.forwarding) = 0 ]"
  expect "host: vmbr0 has IPv4" on_host "ip -4 -o addr show vmbr0 | grep -q inet"
}

verify_vms() {
  local role
  for role in ol fetcher; do
    vm_spec "$role"
    expect "$role: running" on_host "qm status $VMID | grep -q running"
    expect "$role: starts on boot" on_host "qm config $VMID | grep -qx 'onboot: 1'"
    expect "$role: cloud-init done" vm_ssh "$role" "cloud-init status | grep -q done"
  done
  expect "fetcher: /health answers" vm_ssh fetcher "curl -fsS 127.0.0.1:8081/health"
  if vm_ssh ol "test -f /srv/ol-data/current-version"; then
    expect "ol: /version answers" vm_ssh ol "curl -fsS 127.0.0.1:8080/version"
  else
    echo "SKIP  ol: no Open Library version yet (first build running or failed: journalctl -u ol-refresh)"
  fi
}

# A probe that fails for everyone proves nothing: each target is first reached
# from the ol VM, and only then must the fetcher fail to reach it.
verify_egress() {
  local lan_ip router ol_ip target host port
  lan_ip="$(on_host "ip -4 -o addr show vmbr0 | awk '{print \$4}' | cut -d/ -f1 | head -1")"
  router="$(on_host "ip -4 route show default dev vmbr0 | awk '{print \$3}' | head -1")"
  ol_ip="$(vm_ip ol)"
  for target in "10.20.0.1:8006" "10.20.0.1:22" "$lan_ip:8006" "$ol_ip:22" "$router:53"; do
    host="${target%:*}" port="${target##*:}"
    if [ "$host" = 10.20.0.1 ]; then
      : # the ol VM is not on vmbr1; the host itself listens there, checked below
    elif ! tcp_from_vm ol "$host" "$port"; then
      bad "egress control: ol cannot reach $target either, so this probe proves nothing"; continue
    fi
    if tcp_from_vm fetcher "$host" "$port"; then bad "egress: fetcher reached $target"; else ok "egress: fetcher cannot reach $target"; fi
    if tcp_from_fetcher_container "$host" "$port"; then bad "egress: fetcher container reached $target"; else ok "egress: fetcher container cannot reach $target"; fi
  done
  expect "egress control: host listens on 10.20.0.1:8006" on_host "ss -ltnH 'sport = :8006' | grep -q ."
  expect "egress: fetcher has no IPv6 address" vm_ssh fetcher "! ip -6 -o addr | grep -v ' lo ' | grep -q inet6"
  expect "egress: fetcher reaches the public internet" vm_ssh fetcher "curl -fsS -m 10 -o /dev/null https://www.wikipedia.org"
  expect "egress: fetcher container reaches the public internet" tcp_from_fetcher_container 1.1.1.1 443
}

verify_idempotent() {
  CHANGES=()
  converge_host_packages; converge_host_network; converge_host_firewall
  local role; for role in fetcher ol; do ensure_vm "$role"; done
  if [ "${#CHANGES[@]}" = 0 ]; then ok "a second provision changes nothing"; else bad "a second provision changed: ${CHANGES[*]}"; fi
}

# --external-from user@host: a machine outside the house checks the host's
# public IPv6 address for open ports.
verify_external() {
  local port
  for port in 22 8006 111 3128; do
    if ssh "${SSH_OPTS[@]}" "$EXTERNAL_FROM" "nc -6 -z -w 5 $PVE_HOST $port" >/dev/null 2>&1; then
      bad "exposure: port $port is reachable from $EXTERNAL_FROM"
    else
      ok "exposure: port $port closed from outside"
    fi
  done
  expect "exposure control: $EXTERNAL_FROM has IPv6 (reaches 2606:4700:4700::1111:443)" \
    ssh "${SSH_OPTS[@]}" "$EXTERNAL_FROM" "nc -6 -z -w 5 2606:4700:4700::1111 443"
}

# --recovery: kills each service, then reboots the host. Ask Shane before running.
verify_recovery() {
  vm_ssh fetcher "docker kill the-greatest-fetcher-1" >/dev/null
  sleep 30
  expect "recovery: fetcher back after docker kill" vm_ssh fetcher "curl -fsS 127.0.0.1:8081/health"
  if vm_ssh ol "test -f /srv/ol-data/current-version"; then
    vm_ssh ol "docker kill the-greatest-api-1" >/dev/null
    sleep 30
    expect "recovery: api back after docker kill" vm_ssh ol "curl -fsS 127.0.0.1:8080/version"
  fi
  log "rebooting the host"
  on_host "systemctl reboot" || true
  sleep 60
  local i; for i in $(seq 1 60); do on_host true 2>/dev/null && break; sleep 10; done
  sleep 120
  verify_vms
}

verify_all() {
  verify_host
  verify_vms
  verify_egress
  verify_idempotent
  if [ -n "$EXTERNAL_FROM" ]; then verify_external; fi
  if [ "$RECOVERY" = 1 ]; then verify_recovery; fi
  if [ "$VERIFY_FAILURES" = 0 ]; then log "verify: all passed"; else die "verify: $VERIFY_FAILURES failed"; fi
}
```

The container names follow compose's `<project>-<service>-1` pattern with `COMPOSE_PROJECT_NAME=the-greatest`. Confirm with `vm_ssh fetcher 'docker ps --format {{.Names}}'` and use the real names.

- [ ] **Step 2: Shell tests**

Run: `deployment/home-server/test/run.sh`
Expected: clean.

- [ ] **Step 3: Run verify against the box**

Run: `deployment/home-server/provision --verify`
Expected: every line `PASS` (or the one `SKIP` while the first build runs), ending `verify: all passed`. **Any egress FAIL stops the plan.** The fetcher can't go live until it passes. Debug with `ssh root@"$PVE_HOST" 'iptables-save | grep -A3 tap120'` and `pve-firewall compile`.

- [ ] **Step 4: Commit**

```bash
git add deployment/home-server/lib/verify.sh
git commit -m "home-server: provision --verify (host, VMs, egress block, idempotence, exposure, recovery)"
git push
```

---

### Task 9b: Move the target to the HP Elite Mini (spec §12)

**Files:** `deployment/home-server/lib/{vm,host,verify,common}.sh`, `deployment/home-server/host/firewall/cluster.fw.tmpl`, `deployment/home-server/compose.ol.yml`, `deployment/home-server/test/{render,compose_config}_test.sh`, plus any new test files.

**Requirements** (spec §12 is binding; each one needs a test where it can be tested offline):

1. **Storage from configuration.** `VM_STORAGE` (OS disks, cloud-init drive; default `local-lvm`), `DATA_STORAGE` (ol data disk; default `$VM_STORAGE`) and `IMAGE_STORAGE` (the dir storage holding imported images; default `local`) replace every hard-coded storage name in lib/vm.sh. They are read from the decrypted secrets like the other house values.
2. **ZFS ARC cap.** When `/sys/module/zfs` exists on the host, a new step in converge_host_packages (or a small `converge_host_zfs`):
   - writes `/etc/modprobe.d/zfs.conf` with `options zfs zfs_arc_max=<ARC_MAX_BYTES, default 8589934592>`;
   - sets `/sys/module/zfs/parameters/zfs_arc_max` at runtime;
   - when the file changed and root is on ZFS (`findmnt -no FSTYPE /` = zfs), runs `update-initramfs -u -k all`.
   
   It records a change only when something changed.
3. **Optional IPv6.**
   - `converge_host_network` exports an empty `LAN_IPV6_PREFIX` when vmbr0 has no global IPv6, logging it rather than dying.
   - `render_cluster_fw` leaves no blank or `${…}` lines in the ipsets when the prefix is empty. Add a render_test case for v4-only.
   - `verify_egress`'s IPv6 probe SKIPs (with the reason) when `host_global_ipv6` finds no address.
   - `verify_external`: if the host has no global IPv6, it reads the house's public IPv4 on the host (`curl -4 -fsS https://1.1.1.1/cdn-cgi/trace`, the `ip=` line), and probes that with `nc -4`, using the same closed/inconclusive classifier and the `$EXTERNAL_FROM` control (IPv4 variant: `1.1.1.1 443`). It never prints the address.
4. **Sizes.** vm_spec `ol`: CORES=12, MEM=24576. compose.ol.yml build `cpus: 10`, with the comment updated. Update compose_config_test.
5. **Untouched guests.** `verify_all` records the running VMIDs other than 110/120 at its start, and after `verify_idempotent` asserts each one is still running: "pre-existing guest <id> still running".
6. `deployment/home-server/test/run.sh` green, plus the data-sources checks if touched. Commit, push.

**Then run it against the Mini** (only after the commit is pushed):
- `provision --ref worktree-home-server`, then `provision` again (expect `no changes`), then `provision --verify`.
- Expect the host package step to upgrade Proxmox 9.0 → 9.2 (no reboot), the enterprise repo to be disabled, vmbr1 created through the armed revert, the firewall enabled through the armed revert, and VMs 110/120 created on `local-zfs` with the ol data disk on `rpool2`.
- VM 101 must be running after every step.
- STOP and report on any failure. Never touch VM 101, and never reboot.

---

### Task 10: First build and measurements (real box)

> Runs on the Elite Mini after Task 9b (spec §12).

**Files:**
- Create: `docs/features/home-server.md` (its "Measured" section; Task 11 writes the rest)

**Interfaces:**
- Consumes: the running `ol` VM's first `ol-refresh` run.

- [ ] **Step 1: Sample memory while the first build runs**

The first build starts by itself 10 minutes after `ol` boots. Sample it from outside, so the measurement doesn't depend on the build's own logging:

```bash
source deployment/home-server/lib/common.sh; source deployment/home-server/lib/vm.sh; load_secrets
vm_ssh ol 'nohup sh -c "while sleep 30; do date -Is; free -m | sed -n 2p; docker stats --no-stream --format \"{{.Name}} {{.MemUsage}} {{.CPUPerc}}\"; done" > /tmp/build-sample.log 2>&1 &'
```

- [ ] **Step 2: Wait for the build to finish**

Poll every 15 minutes, not more often: `vm_ssh ol 'systemctl is-active ol-refresh; journalctl -u ol-refresh --no-pager | tail -5'`. Expected after about 2–3 hours: `inactive`, with the log ending `serving <date>`. If it ends in `refresh failed`, read the full journal and stop to report. A gate failure on a new dump is a data finding for Shane, not something to work around.

- [ ] **Step 3: Record what the build cost**

```bash
vm_ssh ol 'journalctl -u ol-refresh --no-pager | grep -E "  [a-z_]+: [0-9.]+s|gate |built "'
vm_ssh ol 'awk "/Mem:/ {print \$3}" /tmp/build-sample.log | sort -n | tail -1; grep -E "build" /tmp/build-sample.log | sort -k2 -h | tail -1'
vm_ssh ol 'du -sh /srv/ol-data/*; df -h /srv/ol-data /'
```

Note the per-stage times, the total, the peak VM memory used, the peak build-container memory, and the disk use.

- [ ] **Step 4: Time `/resolve` and retrieval on this box**

```bash
vm_ssh ol 'for i in 1 2 3; do curl -s -o /dev/null -w "%{time_total}\n" -X POST 127.0.0.1:8080/resolve -H "content-type: application/json" -d "{\"title\":\"The Great Gatsby\",\"author_names\":[\"F. Scott Fitzgerald\"],\"year\":1925}"; done'
vm_ssh ol 'for k in OL468431W; do curl -s -o /dev/null -w "works %{time_total}\n" 127.0.0.1:8080/works/$k; curl -s -o /dev/null -w "editions %{time_total}\n" 127.0.0.1:8080/works/$k/editions; done'
vm_ssh ol 'curl -s -o /dev/null -w "isbn %{time_total}\n" 127.0.0.1:8080/identifiers/isbn13/9780743273565'
```

Expected: `/resolve` well under 60 s. **If any `/resolve` takes over 40 s, or the build's peak exceeded the VM's 16 GB, stop and report.** Spec §9 says the §5 sizes change before go-live; that's Shane's call.

- [ ] **Step 5: The fetcher smoke check, from the VM**

```bash
vm_ssh fetcher 'curl -s -X POST 127.0.0.1:8081/fetch -H "content-type: application/json" -d "{\"url\":\"https://www.goodreads.com/book/show/4671.The_Great_Gatsby\",\"wait_for_selector\":\"h1\"}" | jq "{status, title, selector_found, elapsed_ms}"'
vm_ssh fetcher "curl -s -X POST 127.0.0.1:8081/fetch -H 'content-type: application/json' -d '{\"url\":\"https://bookshop.org/book/9780743273565\",\"wait_for_selector\":\"td:has-text(\\\"EAN/UPC\\\")\"}' | jq '{status, title, selector_found, elapsed_ms}'"
```

Expected: Goodreads `status: 200`, a Gatsby title, `selector_found: true`. bookshop.org: a real title, not "Just a moment…", with `selector_found: true`. This is the first time the fetcher runs from the house's residential IP, so record the result either way.

- [ ] **Step 6: Write the measurements**

Create `docs/features/home-server.md` with only a `## Measured` section for now, holding tables of what Steps 3–5 printed: date, dump date, box (i7-7700K, `ol` 8 vCPU / 16 GB). Write numbers you saw, not estimates. Task 11 writes the rest of the page around it.

- [ ] **Step 7: Stop the sampler and commit**

```bash
vm_ssh ol 'pkill -f build-sample || true'
git add docs/features/home-server.md
git commit -m "home-server: first build and service timings on the box"
```

---

### Task 11: Documentation

**Files:**
- Modify: `docs/features/home-server.md` (everything above "Measured")
- Modify: `docs/features/open-library-data-service.md` ("Promoting a new version"), `docs/features/page-fetcher-service.md` ("Where it runs")

- [ ] **Step 1: Write `docs/features/home-server.md`**

Sections, in this order, written as present-tense facts with no class-level code docs (per `docs/documentation.md`):

1. **What it is**: two services, the box (i7-7700K, 32 GB, 2 TB NVMe, Proxmox 9), reached by production through `ol-api.thegreatestbooks.org` and `page-fetcher.thegreatestbooks.org` behind Cloudflare Access. Link the spec.
2. **Layout**: the spec §2 diagram; the VM table from spec §5; `vmbr1`; where the data lives (`/srv/ol-data`, own disk).
3. **Running provision**: `export SOPS_AGE_KEY_FILE=~/.config/sops/age/production.txt`, the five modes with one line each, `--ref`. WSL needs `networkingMode=mirrored` to reach the host's IPv6 address.
4. **What happens without anyone**: the failure → recovery table from the spec's Section 5 conversation (power cut, container exit, bad deploy, bad dump, box offline), naming the unit or setting responsible for each.
5. **Alerts**: the healthchecks.io table from spec §8, including "`ol-heartbeat` is down until the first build finishes".
6. **Rebuild runbook**: spec §10, verbatim steps.
7. **Done once by hand**: BIOS "Restore on AC Power Loss" → Power On; remove the installer USB; the Cloudflare checklist (spec §7); the healthchecks.io checks.
8. **If the ISP changes the IPv6 prefix**: the host's static IPv6 address stops working. SSH in over its LAN IPv4 address instead (the router's DHCP page lists `pve`), fix the address in `/etc/network/interfaces`, then re-run `provision`, which rewrites the `lan` ipset from the host's new route.
9. **Measured**: from Task 10.

- [ ] **Step 2: Update the two service docs**

In `docs/features/open-library-data-service.md`, replace the body of "Promoting a new version" with: on the home server, promotion is automatic. `ol-refresh.timer` builds the newest dump daily if it's new, promotes it only when every gate passes, and keeps two versions (see `docs/features/home-server.md`). The manual `OL_DATA_VERSION=<date> docker compose up -d api` still applies on a development machine.

In `docs/features/page-fetcher-service.md`, replace "Where it runs" with: production runs on the home server's `fetcher` VM (`docs/features/home-server.md`), behind Cloudflare Access. The network-level egress block the address checks call for is in place there. It's enforced on the Proxmox host (`/etc/pve/firewall/120.fw`), and `provision --verify` tests it from inside both the VM and the container. Development still runs it from `data-sources/`.

Also update the "What the address checks do not cover" paragraph's last sentence to say the egress block now exists in production.

- [ ] **Step 3: Run the avoid-ai-writing skill on the new page**

Invoke the `avoid-ai-writing` skill in edit mode on `docs/features/home-server.md`, per the memory rule for public copy. The repo is public.

- [ ] **Step 4: Commit**

```bash
git add docs/features
git commit -m "docs: home server feature page; both services now run there"
git push
```

---

### Task 12: Go-live (needs Shane at each marked step)

**Files:**
- Modify: `secrets/home-server.env`, `secrets/.env.production` (SOPS; Shane holds the values)

- [ ] **Step 1: Hand Shane his checklist**

Send him, as one message:
1. **BIOS:** "Restore on AC Power Loss" → *Power On*. Remove the installer USB stick.
2. **Cloudflare** (his tool): the two tunnels (`home-ol` → `http://api:8080`, `home-fetcher` → `http://fetcher:8081`); two Access applications with one Service Auth policy each for the token `prod-rails`; exempt both hostnames from Bot Fight Mode and bot/WAF challenges. Access goes on before routing.
3. **healthchecks.io:** create the five checks from spec §8 with those periods and graces, email alerts on.
4. **Secrets:** run `sops secrets/home-server.env` and fill the two tunnel tokens and the five ping URLs; then `sops secrets/.env.production` and add `OPEN_LIBRARY_SERVICE_URL`, `PAGE_FETCHER_SERVICE_URL`, `CLOUDFLARE_ACCESS_CLIENT_ID` and `CLOUDFLARE_ACCESS_CLIENT_SECRET` (values in `deployment/ENV.md`).
5. **An outside machine with IPv6** for the exposure check, e.g. `deploy@<prod box>`, if it has IPv6.

Wait for him to confirm each item.

- [ ] **Step 2: Push the filled secrets to the VMs**

Run: `deployment/home-server/provision`
Expected: `ol env` and `fetcher env` changed; the healthchecks.io deploy checks go green within 15 minutes.

- [ ] **Step 3: Turn on the tunnels**

Run: `deployment/home-server/provision --enable-tunnels`
Then check: `vm_ssh fetcher 'docker logs the-greatest-cloudflared-1 2>&1 | grep -c "Registered tunnel connection"'`. Do the same for `ol`. Expected: ≥1 each.

- [ ] **Step 4: Prove Access is in front**

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://ol-api.thegreatestbooks.org/version
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://page-fetcher.thegreatestbooks.org/fetch
```

Expected: `302` or `403`, never `200`. **A 200 means a service is open to the internet: run `ssh root@"$PVE_HOST" 'rm /etc/the-greatest-home-server/tunnels-enabled'`, then `provision` and `vm_ssh <role> 'cd /opt/the-greatest && sudo deployment/home-server/guest/compose.sh stop cloudflared'`, and tell Shane.**

- [ ] **Step 5: Exposure from outside, and the recovery test (ask first)**

Ask Shane before the `--recovery` part, because it reboots the host. Then:
`deployment/home-server/provision --verify --external-from <his outside host> --recovery`
Expected: `verify: all passed`, including the four exposure lines and the recovery lines after the reboot.

- [ ] **Step 6: End to end from production**

This runs after the branch is merged and deployed, since production needs Task 2's code. Ask Shane to run, or to OK running, in a production Rails console:

```ruby
Books::OpenLibrary::Client.new.version
PageFetcher::Client.new.fetch("https://www.goodreads.com/book/show/4671.The_Great_Gatsby").status
```

Expected: a version object naming the served dump date; `200`.

- [ ] **Step 7: Move the VMs onto `main` after merge**

Run: `deployment/home-server/provision --ref main`
Expected: both env files changed, and the deploys switch to `main` (`journalctl -u the-greatest-deploy` on each VM shows the new SHA).

- [ ] **Step 8: Close out**

Update the memory files `proxmox-home-server.md` and `openlibrary-service-not-in-prod.md` with what shipped, and mark the latter superseded.
