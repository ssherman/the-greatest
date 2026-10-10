"""Export file in, model file and manifest out (spec 2 §4.2–4.3). Two fits:
one on the hold-one-out split for the manifest's evaluation, one on
everything for the published model."""

from __future__ import annotations

import csv
import gzip
import io
from dataclasses import dataclass
from pathlib import Path

from . import ease, evaluate, manifest, pairs


@dataclass(frozen=True)
class TrainResult:
    csv_gz: bytes
    manifest: dict


def train_model(
    input_path: Path,
    *,
    domain: str,
    export_name: str,
    lam: float,
    min_readers: int,
    top_k: int,
    eval_seed: int,
    previous: str | None,
) -> TrainResult:
    matrix = pairs.build_matrix(pairs.read_pairs(input_path), min_readers=min_readers)
    n_items = matrix.X.shape[1]

    split = evaluate.hold_one_out(matrix.X, seed=eval_seed)
    eval_rows, eval_cols, eval_weights = ease.top_neighbors(ease.fit(split.train, lam), top_k)
    eval_result = evaluate.metrics(
        split.train,
        ease.to_sparse(eval_rows, eval_cols, eval_weights, n_items),
        split.users,
        split.held,
    )
    eval_result = {"seed": eval_seed, **eval_result}

    rows, cols, weights = ease.top_neighbors(ease.fit(matrix.X, lam), top_k)
    buffer = io.BytesIO()
    with gzip.GzipFile(fileobj=buffer, mode="wb") as gz:
        text = io.TextIOWrapper(gz, encoding="utf-8", newline="")
        writer = csv.writer(text)
        writer.writerow(["item_id", "neighbor_id", "weight"])
        item_ids = matrix.item_index[rows]
        neighbor_ids = matrix.item_index[cols]
        for item_id, neighbor_id, weight in zip(item_ids, neighbor_ids, weights, strict=True):
            writer.writerow([int(item_id), int(neighbor_id), f"{weight:.6g}"])
        text.flush()
        text.detach()

    built = manifest.build(
        domain=domain,
        export=export_name,
        lam=lam,
        min_readers=min_readers,
        top_k=top_k,
        users=matrix.X.shape[0],
        items=n_items,
        rows=len(rows),
        eval_result=eval_result,
        previous=previous,
    )
    return TrainResult(csv_gz=buffer.getvalue(), manifest=built)
