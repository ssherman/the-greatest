"""The two entry points (spec 2 §4.1).

train   files in, files out -- development and the harness loop
run     store in, store out -- what the home server's timer executes:
        pull `latest`, train, gate against the previous manifest, push,
        move the pointer only on a pass
"""

from __future__ import annotations

import json
from datetime import UTC, date, datetime
from pathlib import Path

import typer

from . import manifest as manifest_mod
from . import store as store_mod
from .train import train_model

app = typer.Typer(add_completion=False)

LAMBDA = typer.Option(500.0, "--lambda", help="EASE regularisation")
MIN_READERS = typer.Option(5, help="Drop books with fewer readers")
TOP_K = typer.Option(50, help="Neighbours kept per book")
EVAL_SEED = typer.Option(1, help="Seed for the hold-one-out evaluation")
GATE_RATIO = typer.Option(0.9, help="New hit@10 must be at least this × the previous model's")


def _report(result_manifest: dict) -> None:
    e = result_manifest["eval"]
    m = result_manifest
    typer.echo(
        f"{m['export']}: {m['users']} users, {m['items']} items, {m['rows']} rows; "
        f"hit@10 {e['hit_at_10']:.3f} recall@50 {e['recall_at_50']:.3f} over {e['users']} users"
    )


@app.command()
def train(
    input: Path = typer.Option(..., exists=True, dir_okay=False),
    output_dir: Path = typer.Option(..., file_okay=False),
    name: str = typer.Option(..., help="Model version; the export name it was trained on"),
    domain: str = typer.Option("books"),
    lam: float = LAMBDA,
    min_readers: int = MIN_READERS,
    top_k: int = TOP_K,
    eval_seed: int = EVAL_SEED,
) -> None:
    result = train_model(
        input,
        domain=domain,
        export_name=name,
        lam=lam,
        min_readers=min_readers,
        top_k=top_k,
        eval_seed=eval_seed,
        previous=None,
    )
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / f"{name}.csv.gz").write_bytes(result.csv_gz)
    (output_dir / f"{name}.json").write_text(json.dumps(result.manifest, indent=2) + "\n")
    _report(result.manifest)


def _export_date(name: str) -> date:
    try:
        return date.fromisoformat(name[:10])
    except ValueError as error:
        raise typer.BadParameter(f"export name {name!r} does not start with a date") from error


@app.command()
def run(
    domain: str = typer.Option("books"),
    store_dir: Path | None = typer.Option(
        None, help="A local store instead of R2 (tests, development)"
    ),
    work_dir: Path = typer.Option(Path("/work"), file_okay=False),
    lam: float = LAMBDA,
    min_readers: int = MIN_READERS,
    top_k: int = TOP_K,
    eval_seed: int = EVAL_SEED,
    gate_ratio: float = GATE_RATIO,
    max_export_age_days: int = typer.Option(3, help="Refuse an export older than this"),
) -> None:
    store = store_mod.Local(store_dir) if store_dir else store_mod.R2.from_env()
    if store is None:
        typer.echo("no store: pass --store-dir or set the RECOMMENDATIONS_R2_* variables")
        raise typer.Exit(1)

    name = store.read_pointer(store_mod.interactions_latest(domain))
    if name is None:
        typer.echo(f"no export published for {domain}")
        raise typer.Exit(1)
    age = (datetime.now(UTC).date() - _export_date(name)).days
    if age > max_export_age_days:
        typer.echo(f"export {name} is older than {max_export_age_days} days ({age}); not training")
        raise typer.Exit(1)

    previous = store.read_pointer(store_mod.model_latest(domain))
    if previous and name < previous:
        typer.echo(f"export {name} is not newer than the published model {previous}; not training")
        raise typer.Exit(1)
    if previous == name:
        typer.echo(f"{name} already trained; nothing to do")
        return
    previous_manifest = (
        json.loads(store.get(store_mod.manifest_key(domain, previous))) if previous else None
    )

    work_dir.mkdir(parents=True, exist_ok=True)
    input_path = work_dir / f"{name}.csv.gz"
    input_path.write_bytes(store.get(store_mod.interactions_key(domain, name)))

    try:
        result = train_model(
            input_path,
            domain=domain,
            export_name=name,
            lam=lam,
            min_readers=min_readers,
            top_k=top_k,
            eval_seed=eval_seed,
            previous=previous,
        )
    finally:
        input_path.unlink(missing_ok=True)
    store.put(store_mod.model_key(domain, name), result.csv_gz)
    store.put(
        store_mod.manifest_key(domain, name),
        (json.dumps(result.manifest, indent=2) + "\n").encode(),
    )
    _report(result.manifest)

    ok, reason = manifest_mod.gate(result.manifest, previous_manifest, gate_ratio)
    if not ok:
        typer.echo(f"gate failed: {reason}; latest stays {previous}")
        raise typer.Exit(1)
    store.write_pointer(store_mod.model_latest(domain), name)
    typer.echo(f"published {name} ({reason})")


if __name__ == "__main__":
    app()
