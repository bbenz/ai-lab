#!/usr/bin/env python3
"""LAB723 load generator.

Sends a steady stream of predictions to TARGET_URL from LOAD_CONCURRENCY workers until the pod stops. Every
REPORT_SECONDS, it logs the request rate, the latency, and how many inference pods answered. Each request uses a new
connection, so the Kubernetes Service spreads the load across every ready inference pod, including new replicas that
the Horizontal Pod Autoscaler adds. Only the Python standard library is used.
"""

import http.client
import json
import os
import random
import signal
import sys
import threading
import time
import urllib.parse

from samples import SAMPLES

TARGET_URL = os.environ.get("TARGET_URL", "http://inference.ai-lab.svc.cluster.local").strip().rstrip("/")
TARGET_PATH = os.environ.get("TARGET_PATH", "/predict").strip() or "/predict"
CONCURRENCY = max(1, int(os.environ.get("LOAD_CONCURRENCY", "8")))
REPORT_SECONDS = max(1.0, float(os.environ.get("REPORT_SECONDS", "15")))
TIMEOUT = float(os.environ.get("REQUEST_TIMEOUT", "10"))

STOP = threading.Event()
LOCK = threading.Lock()
WINDOW = {"latencies": [], "errors": 0, "pods": set(), "last_error": ""}


def send(parts, text):
    connection = http.client.HTTPConnection(parts.hostname, parts.port, timeout=TIMEOUT)
    started = time.perf_counter()
    try:
        connection.request("POST", TARGET_PATH, body=json.dumps({"text": text}).encode("utf-8"),
                           headers={"Content-Type": "application/json", "Connection": "close"})
        response = connection.getresponse()
        data = response.read()
    finally:
        connection.close()
    elapsed_ms = (time.perf_counter() - started) * 1000
    if response.status != 200:
        raise RuntimeError(f"HTTP {response.status}")
    return elapsed_ms, json.loads(data).get("pod", "")


def worker(parts, seed):
    rng = random.Random(seed)
    while not STOP.is_set():
        try:
            elapsed_ms, pod = send(parts, rng.choice(SAMPLES))
            with LOCK:
                WINDOW["latencies"].append(elapsed_ms)
                WINDOW["pods"].add(pod)
        except Exception as error:
            with LOCK:
                WINDOW["errors"] += 1
                WINDOW["last_error"] = " ".join(f"{type(error).__name__}: {error}".split())[:200]
            STOP.wait(1.0)  # Don't spin while the service is unavailable.


def report():
    while not STOP.wait(REPORT_SECONDS):
        with LOCK:
            latencies = sorted(WINDOW["latencies"])
            errors, last_error = WINDOW["errors"], WINDOW["last_error"]
            pods = len(WINDOW["pods"] - {""})
            WINDOW.update(latencies=[], errors=0, pods=set(), last_error="")
        if latencies:
            p50 = latencies[len(latencies) // 2]
            p95 = latencies[min(len(latencies) - 1, int(len(latencies) * 0.95))]
            line = (f"loadgen: {len(latencies) / REPORT_SECONDS:.1f} req/s, p50 {p50:.0f} ms, p95 {p95:.0f} ms, "
                    f"errors {errors}, inference pods answering {pods}")
        else:
            line = f"loadgen: no successful requests in the last {REPORT_SECONDS:.0f} s, errors {errors}"
        if errors and last_error:
            line += f" (last error: {last_error})"
        print(line, flush=True)


def main():
    parts = urllib.parse.urlsplit(TARGET_URL if "://" in TARGET_URL else "http://" + TARGET_URL)
    # This process is PID 1 in the container, which has no default handler for SIGTERM.
    signal.signal(signal.SIGTERM, lambda *_: STOP.set())
    signal.signal(signal.SIGINT, lambda *_: STOP.set())
    print(f"loadgen: sending predictions to {parts.scheme}://{parts.netloc}{TARGET_PATH} "
          f"from {CONCURRENCY} workers", flush=True)
    threads = [threading.Thread(target=worker, args=(parts, index), daemon=True) for index in range(CONCURRENCY)]
    threads.append(threading.Thread(target=report, daemon=True))
    for thread in threads:
        thread.start()
    while not STOP.wait(1.0):
        pass
    print("loadgen: stopping", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
