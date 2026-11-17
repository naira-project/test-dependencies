"""Seed Langfuse with demo LLM traces, generations and scores, then replay the
langfuse plugin's metrics queries against them.

Two ingestion paths: v4 defaults to LANGFUSE_MIGRATION_V4_WRITE_MODE=events_only,
so /api/public/ingestion takes score events only and traces and generations must
arrive over OTLP. That payload is hand-written to keep `requests` the only
dependency.
"""

import json
import os
import random
import sys
import time
import uuid
from datetime import datetime, timedelta, timezone

import requests

HOST = os.environ.get("LANGFUSE_HOST", "http://langfuse-web:3000").rstrip("/")
AUTH = (os.environ["LANGFUSE_PUBLIC_KEY"], os.environ["LANGFUSE_SECRET_KEY"])
TIMEOUT = 60

# The Job can start while langfuse-web is still running ClickHouse migrations.
READY_ATTEMPTS = 60
READY_INTERVAL = 5

# Ingestion is async: the API accepts spans, a worker moves them to ClickHouse.
SETTLE_ATTEMPTS = 30
SETTLE_INTERVAL = 10

# (model, input cost per token, output cost per token). Stated on the spans, not
# left to Langfuse's price table: totals then survive its updates and unknown models.
MODELS = [
    ("gpt-4o-mini", 0.00000015, 0.0000006),
    ("gpt-4o", 0.0000025, 0.00001),
    ("claude-haiku-4-5", 0.000001, 0.000005),
]

# Deterministic so a reseed reports comparable numbers.
random.seed(20260930)


def load_apps() -> list[dict]:
    """Reads seed.langfuse.apps, passed through as JSON by the chart."""
    raw = os.environ.get("LANGFUSE_SEED_APPS", "").strip()
    if not raw:
        raise SystemExit("LANGFUSE_SEED_APPS is empty; nothing to seed")
    apps = json.loads(raw)
    for app in apps:
        # A thumbs up/down ratio: the aggregate mean is the share of positives.
        app.setdefault("scoreValues", [0, 1])
    return apps


def iso(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).isoformat()


def unix_nano(moment: datetime) -> str:
    """OTLP timestamps: nanoseconds since the epoch, as strings."""
    # Microseconds as an int first: float64 cannot hold nanoseconds exactly.
    return str(int(moment.timestamp() * 1_000_000) * 1000)


def attribute(key: str, value) -> dict:
    """One OTLP key/value. bool is checked first, being a subclass of int."""
    if isinstance(value, bool):
        typed = {"boolValue": value}
    elif isinstance(value, int):
        typed = {"intValue": str(value)}
    elif isinstance(value, float):
        typed = {"doubleValue": value}
    else:
        typed = {"stringValue": str(value)}
    return {"key": key, "value": typed}


def wait_for_ready() -> None:
    for attempt in range(1, READY_ATTEMPTS + 1):
        try:
            resp = requests.get(f"{HOST}/api/public/health", timeout=10)
            if resp.status_code < 400:
                return
            detail = str(resp.status_code)
        except requests.RequestException as err:
            detail = type(err).__name__
        print(f"  waiting for {HOST} ({detail}) {attempt}/{READY_ATTEMPTS}", flush=True)
        time.sleep(READY_INTERVAL)
    raise SystemExit(f"{HOST} did not become ready")


def build_spans(app: dict, now: datetime) -> tuple[list[dict], list[dict]]:
    """Builds the OTLP spans for one app, plus its score events.

    Each trace is a root span with generation children. Langfuse's own attribute
    names are used over the gen_ai.* ones: it reads both, but its own are
    unambiguous about observation type and cost.
    """
    spans: list[dict] = []
    scores: list[dict] = []
    window_seconds = app["windowHours"] * 3600

    for _ in range(app["traces"]):
        # Langfuse reuses the OTel trace id, so the scores below attach by it.
        trace_id = uuid.uuid4().hex
        root_span_id = uuid.uuid4().hex[:16]

        # Headroom at both ends, or counts stop matching: a trace starting at
        # `now` would have children past toTimestamp, one at the far edge would
        # lose children off fromTimestamp.
        started = now - timedelta(
            seconds=random.uniform(window_seconds * 0.03, window_seconds * 0.97)
        )

        generations = []
        cursor = started
        for step in range(random.randint(1, 3)):
            model, input_rate, output_rate = random.choice(MODELS)
            input_tokens = random.randint(200, 3000)
            output_tokens = random.randint(50, 800)
            # Skewed, so the averages are not uniform noise and a tail exists.
            ended = cursor + timedelta(seconds=random.lognormvariate(0.2, 0.6))
            input_cost = input_tokens * input_rate
            output_cost = output_tokens * output_rate

            generations.append(
                {
                    "traceId": trace_id,
                    "spanId": uuid.uuid4().hex[:16],
                    "parentSpanId": root_span_id,
                    "name": f"llm-call-{step + 1}",
                    "kind": 3,  # SPAN_KIND_CLIENT
                    # Their difference is what the plugin's avg_latency measures.
                    "startTimeUnixNano": unix_nano(cursor),
                    "endTimeUnixNano": unix_nano(ended),
                    "attributes": [
                        # Without this it lands as a plain span, uncounted by
                        # the observations view.
                        attribute("langfuse.observation.type", "generation"),
                        # On every span: the traceName column the plugin filters on.
                        attribute("langfuse.trace.name", app["traceName"]),
                        attribute("langfuse.observation.model.name", model),
                        attribute(
                            "langfuse.observation.usage_details",
                            json.dumps(
                                {
                                    "input": input_tokens,
                                    "output": output_tokens,
                                    "total": input_tokens + output_tokens,
                                }
                            ),
                        ),
                        attribute(
                            "langfuse.observation.cost_details",
                            json.dumps(
                                {
                                    "input": input_cost,
                                    "output": output_cost,
                                    "total": input_cost + output_cost,
                                }
                            ),
                        ),
                    ],
                }
            )
            cursor = ended

        spans.append(
            {
                "traceId": trace_id,
                "spanId": root_span_id,
                "name": app["traceName"],
                "kind": 1,  # SPAN_KIND_INTERNAL
                "startTimeUnixNano": unix_nano(started),
                "endTimeUnixNano": unix_nano(cursor),
                "attributes": [
                    attribute("langfuse.trace.name", app["traceName"]),
                    attribute("langfuse.user.id", f"user-{random.randint(1, 25)}"),
                    attribute("langfuse.session.id", f"session-{random.randint(1, 60)}"),
                    attribute("langfuse.trace.tags", json.dumps(["naira-demo"])),
                ],
            }
        )
        spans.extend(generations)

        # Not every trace is rated, so the two counts on the tiles differ.
        if random.random() < 0.7:
            scores.append(
                {
                    "id": str(uuid.uuid4()),
                    "type": "score-create",
                    "timestamp": iso(cursor),
                    "body": {
                        "id": str(uuid.uuid4()),
                        "traceId": trace_id,
                        "name": app["scoreName"],
                        "value": random.choice(app["scoreValues"]),
                        "dataType": "NUMERIC",
                    },
                }
            )

    return spans, scores


def ingest_spans(spans: list[dict]) -> None:
    batch_size = 200
    sent = 0

    for start in range(0, len(spans), batch_size):
        batch = spans[start : start + batch_size]
        payload = {
            "resourceSpans": [
                {
                    "resource": {
                        "attributes": [attribute("service.name", "naira-langfuse-seed")]
                    },
                    "scopeSpans": [{"scope": {"name": "naira-seed"}, "spans": batch}],
                }
            ]
        }
        resp = requests.post(
            f"{HOST}/api/public/otel/v1/traces", json=payload, auth=AUTH, timeout=TIMEOUT
        )
        if resp.status_code >= 400:
            raise SystemExit(f"OTLP ingestion failed: {resp.status_code} {resp.text[:800]}")

        # OTLP answers 200 with partialSuccess when it drops spans.
        partial = (resp.json() if resp.content else {}).get("partialSuccess") or {}
        if partial.get("rejectedSpans"):
            raise SystemExit(
                f"OTLP rejected {partial['rejectedSpans']} spans: "
                f"{partial.get('errorMessage', '')}"
            )

        sent += len(batch)
        print(f"  sent {sent}/{len(spans)} spans", flush=True)


def ingest_scores(events: list[dict]) -> None:
    """Posts score events, the one event type v4 still takes on this endpoint."""
    batch_size = 100
    accepted = 0

    for start in range(0, len(events), batch_size):
        batch = events[start : start + batch_size]
        resp = requests.post(
            f"{HOST}/api/public/ingestion", json={"batch": batch}, auth=AUTH, timeout=TIMEOUT
        )
        # 207: events succeed or fail one by one, so 2xx alone proves nothing.
        if resp.status_code >= 400:
            raise SystemExit(f"score ingestion failed: {resp.status_code} {resp.text[:500]}")

        payload = resp.json() if resp.content else {}
        errors = payload.get("errors") or []
        if errors:
            raise SystemExit(
                f"score ingestion rejected events: {json.dumps(errors[:3], indent=2)}"
            )

        accepted += len(payload.get("successes") or batch)
        print(f"  ingested {accepted}/{len(events)} scores", flush=True)


def metrics_query(
    view: str,
    metrics: list[dict],
    filters: list[dict],
    from_time: datetime,
    to_time: datetime,
) -> list[dict]:
    """One metrics query, as plugins/cmd/langfuse/client.go makes it: a GET with
    the query object JSON-encoded into the `query` parameter, authenticated with
    the key pair as HTTP Basic credentials.
    """
    query = {
        "view": view,
        "metrics": metrics,
        "dimensions": [],
        "filters": filters,
        "fromTimestamp": iso(from_time),
        "toTimestamp": iso(to_time),
    }
    resp = requests.get(
        f"{HOST}/api/public/v2/metrics",
        params={"query": json.dumps(query)},
        auth=AUTH,
        timeout=TIMEOUT,
    )
    if resp.status_code >= 400:
        raise SystemExit(
            f"metrics query failed: {resp.status_code} {resp.text[:500]}\n"
            f"query was: {json.dumps(query, indent=2)}"
        )
    return resp.json().get("data", [])


def trace_filter(trace_name: str) -> list[dict]:
    return [{"column": "traceName", "operator": "=", "value": trace_name, "type": "string"}]


def score_filter(score_name: str) -> dict:
    return {"column": "name", "operator": "=", "value": score_name, "type": "string"}


def row_count(rows: list[dict]) -> int:
    """Reads count_count out of a metrics row, treating absent as zero."""
    return int(rows[0].get("count_count") or 0) if rows else 0


def counts(app: dict, now: datetime) -> tuple[int, int]:
    """Observation and score counts currently queryable for this app."""
    from_time = now - timedelta(hours=app["windowHours"])
    observations = row_count(
        metrics_query(
            "observations",
            [{"measure": "count", "aggregation": "count"}],
            trace_filter(app["traceName"]),
            from_time,
            now,
        )
    )
    scores = row_count(
        metrics_query(
            "scores-numeric",
            [{"measure": "count", "aggregation": "count"}],
            trace_filter(app["traceName"]) + [score_filter(app["scoreName"])],
            from_time,
            now,
        )
    )
    return observations, scores


def wait_for_ingestion(app: dict, now: datetime, expected: tuple[int, int]) -> bool:
    """Polls until everything seeded for this app is queryable.

    The first row is not enough: ingestion streams in, and a half-filled window
    yields aggregates that look plausible and are wrong.
    """
    want_observations, want_scores = expected
    previous = None

    for attempt in range(1, SETTLE_ATTEMPTS + 1):
        observations, scores = counts(app, now)
        if observations >= want_observations and scores >= want_scores:
            print(
                f"  {app['traceName']}: {observations} observations, "
                f"{scores} scores — complete",
                flush=True,
            )
            return True

        # Stopped moving means ingestion is done and something is missing.
        current = (observations, scores)
        if current == previous and attempt > 2:
            print(
                f"  {app['traceName']}: stalled at {observations}/{want_observations} "
                f"observations, {scores}/{want_scores} scores",
                flush=True,
            )
            return False
        previous = current

        print(
            f"  {app['traceName']}: {observations}/{want_observations} observations, "
            f"{scores}/{want_scores} scores ({attempt}/{SETTLE_ATTEMPTS})",
            flush=True,
        )
        time.sleep(SETTLE_INTERVAL)

    return False


def verify(app: dict, now: datetime) -> bool:
    """Replays the plugin's two queries and checks the keys it reads."""
    from_time = now - timedelta(hours=app["windowHours"])

    observations = metrics_query(
        "observations",
        [
            {"measure": "totalCost", "aggregation": "sum"},
            {"measure": "latency", "aggregation": "avg"},
            {"measure": "count", "aggregation": "count"},
        ],
        trace_filter(app["traceName"]),
        from_time,
        now,
    )
    scores = metrics_query(
        "scores-numeric",
        [
            {"measure": "value", "aggregation": "avg"},
            {"measure": "count", "aggregation": "count"},
        ],
        trace_filter(app["traceName"]) + [score_filter(app["scoreName"])],
        from_time,
        now,
    )

    print(f"\n  {app['traceName']} (last {app['windowHours']}h)")
    print(f"    observations -> {json.dumps(observations)}")
    print(f"    scores       -> {json.dumps(scores)}")

    # The keys the plugin reads: a Langfuse rename then fails this Job rather
    # than showing up as a blank tile in the Naira UI.
    checks = {
        "observations": (observations, ["sum_totalCost", "avg_latency", "count_count"]),
        "scores-numeric": (scores, ["avg_value", "count_count"]),
    }

    ok = True
    for view, (rows, keys) in checks.items():
        if not rows:
            print(f"    WARNING: {view} returned no rows")
            ok = False
            continue
        missing = [key for key in keys if key not in rows[0]]
        if missing:
            print(f"    WARNING: {view} row is missing {missing}")
            print(f"             keys present: {sorted(rows[0].keys())}")
            ok = False
    return ok


def main() -> int:
    apps = load_apps()
    now = datetime.now(timezone.utc)
    expected: dict[str, tuple[int, int]] = {}

    print(f"Seeding Langfuse at {HOST}")
    wait_for_ready()

    for app in apps:
        spans, scores = build_spans(app, now)
        # Only generations are observations; the root span is the trace.
        generations = sum(1 for span in spans if "parentSpanId" in span)

        # Measured before ingesting: on a reseed the rows already there would
        # otherwise satisfy the target and the wait would return mid-stream.
        base_observations, base_scores = counts(app, now)
        expected[app["traceName"]] = (
            base_observations + generations,
            base_scores + len(scores),
        )

        print(
            f"\n{app['traceName']}: {len(spans)} spans ({generations} generations) "
            f"over {app['windowHours']}h"
        )
        if base_observations or base_scores:
            print(
                f"  already present: {base_observations} observations, "
                f"{base_scores} scores — adding to them"
            )
        ingest_spans(spans)
        ingest_scores(scores)

    print("\nWaiting for ingestion to reach ClickHouse...")
    settled = [wait_for_ingestion(app, now, expected[app["traceName"]]) for app in apps]

    # Runs either way: the aggregates tell a shortfall from a broken query.
    print("\nReplaying the plugin's metrics queries against the real API:")
    verified = [verify(app, now) for app in apps]

    if not all(settled):
        print(
            "\nNot everything that was accepted became queryable. If the counts "
            "above stalled short, the worker dropped events rather than lagging:\n"
            "  kubectl -n naira-deps logs deploy/langfuse-worker --tail=100",
            file=sys.stderr,
        )
        return 1

    if not all(verified):
        print(
            "\nThe metrics API answered, but not with the keys the plugin expects. "
            "Reconcile plugins/cmd/langfuse/client.go with the output above.",
            file=sys.stderr,
        )
        return 1

    print(
        "\nAll queries returned the keys the plugin reads. Trigger the langfuse "
        "plugin from the UI's Plugins & Ingestion dialog to pull these in."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
