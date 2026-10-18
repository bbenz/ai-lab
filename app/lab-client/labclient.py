#!/usr/bin/env python3
"""LAB723 lab client: the predict and bench commands.

    predict --target <service> [--text TEXT]
    bench --target <service> [--requests N] [--concurrency C] [--warmup W]

The commands run inside the lab-client pod, so the results reflect the inference service rather than the
attendee's network. A target is a service name in the ai-lab namespace, such as inference or inference-gpu, or a
host:port, or a URL. Only the Python standard library is used.
"""

import argparse
import http.client
import json
import math
import random
import sys
import time
import urllib.parse
from concurrent.futures import ThreadPoolExecutor

from samples import SAMPLES


def predict_url(target):
    target = target.strip()
    if "://" not in target:
        target = "http://" + target
    parts = urllib.parse.urlsplit(target)
    path = parts.path if parts.path not in ("", "/") else "/predict"
    return urllib.parse.urlunsplit((parts.scheme, parts.netloc, path, "", ""))


def call(url, text, timeout):
    """Sends one prediction on a new connection. Returns the round trip in milliseconds and the response."""
    parts = urllib.parse.urlsplit(url)
    connection_type = http.client.HTTPSConnection if parts.scheme == "https" else http.client.HTTPConnection
    connection = connection_type(parts.hostname, parts.port, timeout=timeout)
    body = json.dumps({"text": text}).encode("utf-8")
    started = time.perf_counter()
    try:
        connection.request("POST", parts.path, body=body,
                           headers={"Content-Type": "application/json", "Connection": "close"})
        response = connection.getresponse()
        data = response.read()
    finally:
        connection.close()
    elapsed_ms = (time.perf_counter() - started) * 1000
    if response.status != 200:
        detail = " ".join(data.decode("utf-8", "replace").split())[:300]
        raise RuntimeError(f"HTTP {response.status}: {detail}")
    return elapsed_ms, json.loads(data)


def percentile(sorted_values, percent):
    """Linear interpolation between the closest ranks."""
    if not sorted_values:
        return float("nan")
    rank = (len(sorted_values) - 1) * percent / 100
    low, high = math.floor(rank), math.ceil(rank)
    if low == high:
        return sorted_values[low]
    return sorted_values[low] + (sorted_values[high] - sorted_values[low]) * (rank - low)


def fail(url, error):
    print(f"Couldn't get a prediction from {url}: {error}", file=sys.stderr)
    print("Check that the service is deployed and ready: kubectl get deployment,service -n ai-lab", file=sys.stderr)
    return 1


def run_predict(args):
    url = predict_url(args.target)
    text = args.text or random.choice(SAMPLES)
    try:
        elapsed_ms, result = call(url, text, args.timeout)
    except Exception as error:
        return fail(url, error)
    print(f"Target:          {url}")
    print(f'Input:           "{text}"')
    print(f"Prediction:      {result.get('label')} (score {result.get('score')})")
    print(f"Device:          {result.get('device')}")
    print(f"Pod:             {result.get('pod')}")
    print(f"Server latency:  {result.get('server_ms')} ms (model {result.get('model_ms')} ms)")
    print(f"Round trip:      {elapsed_ms:.1f} ms")
    return 0


def run_bench(args):
    url = predict_url(args.target)

    def one(index):
        try:
            elapsed_ms, result = call(url, SAMPLES[index % len(SAMPLES)], args.timeout)
            return elapsed_ms, result, None
        except Exception as error:
            return None, None, error

    with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        # Warm-up requests aren't counted, so a cold start doesn't skew the results.
        warmup = list(pool.map(one, range(args.warmup)))
        if warmup and all(error for _, _, error in warmup):
            return fail(url, warmup[0][2])
        started = time.perf_counter()
        outcomes = list(pool.map(one, range(args.warmup, args.warmup + args.requests)))
        wall_seconds = time.perf_counter() - started

    latencies = sorted(elapsed for elapsed, _, error in outcomes if error is None)
    results = [result for _, result, error in outcomes if error is None]
    errors = [error for _, _, error in outcomes if error is not None]
    print(f"Benchmark:     {args.requests} requests to {url}, {args.concurrency} at a time, "
          f"after {args.warmup} warm-up requests that aren't counted")
    print(f"Requests:      {len(latencies)} succeeded, {len(errors)} failed")
    if latencies:
        print(f"Latency (ms):  p50 {percentile(latencies, 50):.1f}   p95 {percentile(latencies, 95):.1f}   "
              f"p99 {percentile(latencies, 99):.1f}   mean {sum(latencies) / len(latencies):.1f}")
        print(f"Throughput:    {len(latencies) / wall_seconds:.1f} req/s")
        devices = sorted({str(result.get("device")) for result in results})
        pods = {result.get("pod") for result in results}
        model_ms = [result["model_ms"] for result in results if isinstance(result.get("model_ms"), (int, float))]
        model_text = f", mean model time {sum(model_ms) / len(model_ms):.1f} ms" if model_ms else ""
        print(f"Server:        device {', '.join(devices)}, {len(pods)} pod(s){model_text}")
    if errors:
        print(f"First error:   {errors[0]}", file=sys.stderr)
    return 0 if latencies else 1


def positive(value):
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be 1 or more")
    return number


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    command = argv.pop(0) if argv and argv[0] in ("predict", "bench") else ""
    if not command:
        print("Usage: predict --target <service> | bench --target <service> --requests N --concurrency C", file=sys.stderr)
        return 2
    parser = argparse.ArgumentParser(prog=command)
    parser.add_argument("--target", default="inference", help="Service name in ai-lab, host:port, or URL")
    parser.add_argument("--timeout", type=float, default=30.0, help="Seconds to wait for each response")
    if command == "predict":
        parser.add_argument("--text", help="Text to classify. Default: a random sample review")
        return run_predict(parser.parse_args(argv))
    parser.add_argument("--requests", type=positive, default=200, help="Requests to measure")
    parser.add_argument("--concurrency", type=positive, default=4, help="Requests in flight at the same time")
    parser.add_argument("--warmup", type=int, default=10, help="Requests to send first and not count")
    return run_bench(parser.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
