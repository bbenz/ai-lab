"""LAB723 inference service.

Serves a compact sentiment model, DistilBERT fine-tuned on SST-2 and exported to ONNX, over HTTP:

- POST /predict with {"text": "..."} returns the label, score, device, and the latency that the server measured.
  GET /predict?text=... does the same, for a quick test in a browser.
- GET /healthz reports the status, the model, and the device that serves requests. It's the liveness probe.
- GET /ready returns 200 when the model is loaded. It's the readiness probe.
- GET /metrics returns Prometheus metrics, which Azure Monitor managed Prometheus scrapes through a ServiceMonitor.

At startup, the service downloads the model from Azure Blob Storage by using workload identity. When
APPLICATIONINSIGHTS_CONNECTION_STRING is set, it sends OpenTelemetry traces, metrics, and logs to Application Insights.
"""

import json
import logging
import os
import socket
import threading
import time
from contextlib import asynccontextmanager
from pathlib import Path

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
LOG = logging.getLogger("lab723.inference")

# Configure OpenTelemetry before the FastAPI app is created, so that the FastAPI instrumentation applies to it.
TELEMETRY = "off, because APPLICATIONINSIGHTS_CONNECTION_STRING isn't set"
if os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING", "").strip():
    try:
        from azure.monitor.opentelemetry import configure_azure_monitor

        configure_azure_monitor(logger_name="lab723")
        TELEMETRY = "on, to Application Insights"
    except Exception as error:  # Telemetry must never stop the service.
        TELEMETRY = f"off, because it couldn't start: {error}"

import numpy as np
import onnxruntime as ort
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import JSONResponse, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, Histogram, generate_latest
from pydantic import BaseModel, Field
from tokenizers import Tokenizer


def _setting(name, default=""):
    return os.environ.get(name, default).strip()


MODEL_NAME = _setting("MODEL_NAME", "distilbert-base-uncased-finetuned-sst-2-english")
MODEL_FILES = ("model.onnx", "tokenizer.json", "config.json")
MODEL_ACCOUNT_URL = _setting("MODEL_ACCOUNT_URL").rstrip("/")  # From the lab-environment ConfigMap
MODEL_CONTAINER = _setting("MODEL_CONTAINER", "models")
MODEL_PREFIX = _setting("MODEL_PREFIX").strip("/")  # A folder in the container, if the files aren't at its root
MODEL_LOCAL_DIR = _setting("MODEL_LOCAL_DIR")  # For local testing: read the model from a folder instead
MODEL_CACHE_DIR = Path(_setting("MODEL_CACHE_DIR", "/tmp/model"))
DEVICE_SETTING = _setting("INFERENCE_DEVICE", "cpu").lower()  # cpu or cuda
# Inference runtimes size their thread pools from the node's cores, not the container's CPU limit, so the
# deployment sets the thread count to match its CPU limit.
THREADS = max(1, int(_setting("INFERENCE_THREADS") or _setting("OMP_NUM_THREADS") or "1"))
CONCURRENCY = max(1, int(_setting("INFERENCE_CONCURRENCY", "1")))  # Predictions that run at the same time
MAX_TOKENS = max(8, int(_setting("MAX_TOKENS", "128")))
LOAD_ATTEMPTS = max(1, int(_setting("MODEL_LOAD_ATTEMPTS", "40")))
POD = _setting("HOSTNAME") or socket.gethostname()
VERSION = _setting("APP_VERSION", "1.0.0")

BUCKETS = (0.005, 0.01, 0.02, 0.03, 0.05, 0.075, 0.1, 0.15, 0.2, 0.3, 0.5, 0.75, 1.0, 2.0, 5.0)
REQUESTS = Counter("lab723_inference_requests_total", "Prediction requests, by device and outcome.", ["device", "outcome"])
LATENCY = Histogram(
    "lab723_inference_request_duration_seconds",
    "Time that the server spent on each prediction, including time spent waiting for the model.",
    ["device"],
    buckets=BUCKETS,
)
MODEL_TIME = Histogram(
    "lab723_inference_model_duration_seconds", "Time that the model spent on each prediction.", ["device"], buckets=BUCKETS
)
IN_FLIGHT = Gauge("lab723_inference_in_flight_requests", "Predictions in progress, including waiting ones.")
LOAD_SECONDS = Gauge("lab723_inference_model_load_seconds", "Time that it took to download and load the model.")
INFO = Gauge("lab723_inference_info", "The model and device that this pod serves.", ["model", "device", "version"])

STATE = {"status": "loading", "device": "", "detail": ""}
MODEL = None


def _one_line(error):
    return " ".join(f"{type(error).__name__}: {error}".split())[:500]


def _create_session(path):
    options = ort.SessionOptions()
    options.intra_op_num_threads = THREADS
    options.inter_op_num_threads = 1
    options.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
    options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    # Threads that spin while they wait use CPU time, which counts against the container's CPU limit.
    options.add_session_config_entry("session.intra_op.allow_spinning", _setting("INFERENCE_SPIN", "0"))
    providers = ["CPUExecutionProvider"]
    if DEVICE_SETTING == "cuda":
        preload = getattr(ort, "preload_dlls", None)
        if preload:
            try:
                preload()  # Loads CUDA and cuDNN from the nvidia-* Python packages
            except Exception as error:
                LOG.warning("Couldn't preload the CUDA libraries: %s", _one_line(error))
        if "CUDAExecutionProvider" in ort.get_available_providers():
            providers = ["CUDAExecutionProvider", "CPUExecutionProvider"]
        else:
            LOG.error("INFERENCE_DEVICE is cuda, but this ONNX Runtime build has no CUDA provider.")
    try:
        session = ort.InferenceSession(str(path), options, providers=providers)
    except Exception as error:
        if providers[0] == "CPUExecutionProvider":
            raise
        LOG.error("Couldn't start the model on the GPU, so it runs on the CPU: %s", _one_line(error))
        session = ort.InferenceSession(str(path), options, providers=["CPUExecutionProvider"])
    device = "cuda" if session.get_providers()[0] == "CUDAExecutionProvider" else "cpu"
    if DEVICE_SETTING == "cuda" and device != "cuda":
        LOG.error(
            "No GPU is available to ONNX Runtime, so this pod runs on the CPU. Check that the pod requests "
            "nvidia.com/gpu and runs on a GPU node."
        )
    return session, device


class SentimentModel:
    """The ONNX model and its tokenizer. One prediction runs at a time, so the latency includes queuing."""

    def __init__(self, folder):
        self.session, self.device = _create_session(folder / "model.onnx")
        self.tokenizer = Tokenizer.from_file(str(folder / "tokenizer.json"))
        self.tokenizer.no_padding()
        self.tokenizer.enable_truncation(max_length=MAX_TOKENS)
        config = json.loads((folder / "config.json").read_text(encoding="utf-8"))
        self.labels = {int(key): value for key, value in config.get("id2label", {}).items()}
        self.gate = threading.BoundedSemaphore(CONCURRENCY)

    def classify(self, text):
        encoding = self.tokenizer.encode(text)
        feeds = {
            "input_ids": np.asarray([encoding.ids], dtype=np.int64),
            "attention_mask": np.asarray([encoding.attention_mask], dtype=np.int64),
        }
        with self.gate:
            started = time.perf_counter()
            logits = self.session.run(["logits"], feeds)[0][0]
            model_seconds = time.perf_counter() - started
        exponentials = np.exp(logits - np.max(logits))
        probabilities = exponentials / exponentials.sum()
        index = int(np.argmax(probabilities))
        return self.labels.get(index, str(index)), float(probabilities[index]), model_seconds, len(encoding.ids)


def _download_model():
    """Returns the folder that has the model files, and a description of where they came from."""
    if MODEL_LOCAL_DIR:
        return Path(MODEL_LOCAL_DIR), f"the local folder {MODEL_LOCAL_DIR}"
    if not MODEL_ACCOUNT_URL:
        raise RuntimeError("MODEL_ACCOUNT_URL isn't set. The lab-environment ConfigMap in the ai-lab namespace sets it.")
    from azure.storage.blob import ContainerClient

    if os.environ.get("AZURE_FEDERATED_TOKEN_FILE"):
        from azure.identity import WorkloadIdentityCredential

        credential = WorkloadIdentityCredential()
        method = f"workload identity (client ID {os.environ.get('AZURE_CLIENT_ID', 'unknown')})"
    else:
        from azure.identity import DefaultAzureCredential

        credential = DefaultAzureCredential()
        method = "DefaultAzureCredential, because workload identity isn't set up for this pod"
    MODEL_CACHE_DIR.mkdir(parents=True, exist_ok=True)
    with ContainerClient(MODEL_ACCOUNT_URL, MODEL_CONTAINER, credential=credential) as container:
        for name in MODEL_FILES:
            blob_name = f"{MODEL_PREFIX}/{name}" if MODEL_PREFIX else name
            partial = MODEL_CACHE_DIR / f"{name}.partial"
            with open(partial, "wb") as handle:
                container.download_blob(blob_name, max_concurrency=4).readinto(handle)
            partial.replace(MODEL_CACHE_DIR / name)
    return MODEL_CACHE_DIR, f"Azure Blob Storage ({MODEL_ACCOUNT_URL}/{MODEL_CONTAINER}) by using {method}"


def _load_model():
    """Runs in the background, so that the probes answer while the model loads. Retries while roles propagate."""
    global MODEL
    started = time.perf_counter()
    for attempt in range(1, LOAD_ATTEMPTS + 1):
        try:
            folder, source = _download_model()
            model = SentimentModel(folder)
            for _ in range(3):
                model.classify("Warming up the model before the pod reports that it's ready.")
            break
        except Exception as error:
            STATE["detail"] = _one_line(error)
            if attempt == LOAD_ATTEMPTS:
                STATE["status"] = "error"
                LOG.error("Couldn't load the model after %d attempts: %s", attempt, STATE["detail"])
                return
            delay = min(30, 5 * attempt)
            LOG.warning("Couldn't load the model (attempt %d of %d): %s Retrying in %d s.",
                        attempt, LOAD_ATTEMPTS, STATE["detail"], delay)
            time.sleep(delay)
    elapsed = time.perf_counter() - started
    MODEL = model
    STATE.update(status="ok", device=model.device, detail="")
    LOAD_SECONDS.set(elapsed)
    INFO.labels(MODEL_NAME, model.device, VERSION).set(1)
    LOG.info("Loaded model %s from %s in %.1f s. Device: %s. Threads: %d.",
             MODEL_NAME, source, elapsed, model.device, THREADS)


@asynccontextmanager
async def lifespan(_app):
    LOG.info("LAB723 inference %s is starting on pod %s. Device setting: %s. Threads: %d. Telemetry: %s.",
             VERSION, POD, DEVICE_SETTING, THREADS, TELEMETRY)
    threading.Thread(target=_load_model, name="model-loader", daemon=True).start()
    yield


app = FastAPI(title="LAB723 inference", version=VERSION, lifespan=lifespan)


class PredictRequest(BaseModel):
    text: str = Field(min_length=1, max_length=4000)


def _predict(text):
    model = MODEL
    if model is None:
        raise HTTPException(status_code=503, detail="The model isn't loaded yet.")
    started = time.perf_counter()
    IN_FLIGHT.inc()
    try:
        label, score, model_seconds, tokens = model.classify(text)
    except Exception:
        REQUESTS.labels(model.device, "error").inc()
        LOG.exception("A prediction failed.")
        raise HTTPException(status_code=500, detail="The prediction failed.")
    finally:
        IN_FLIGHT.dec()
    server_seconds = time.perf_counter() - started
    REQUESTS.labels(model.device, "ok").inc()
    LATENCY.labels(model.device).observe(server_seconds)
    MODEL_TIME.labels(model.device).observe(model_seconds)
    return {
        "label": label,
        "score": round(score, 4),
        "device": model.device,
        "model": MODEL_NAME,
        "tokens": tokens,
        "server_ms": round(server_seconds * 1000, 2),
        "model_ms": round(model_seconds * 1000, 2),
        "pod": POD,
    }


@app.post("/predict")
def predict(request: PredictRequest):
    return _predict(request.text)


@app.get("/predict")
def predict_from_query(text: str = Query(min_length=1, max_length=4000)):
    return _predict(text)


@app.get("/healthz")
async def healthz():
    # Async, so that the probes run on the event loop and answer quickly while predictions keep the CPU busy.
    body = {"status": STATE["status"], "model": MODEL_NAME, "device": STATE["device"] or DEVICE_SETTING,
            "pod": POD, "version": VERSION}
    if STATE["status"] != "ok" and STATE["detail"]:
        body["detail"] = STATE["detail"]
    return JSONResponse(body, status_code=503 if STATE["status"] == "error" else 200)


@app.get("/ready")
async def ready():
    is_ready = STATE["status"] == "ok"
    return JSONResponse({"ready": is_ready}, status_code=200 if is_ready else 503)


@app.get("/metrics")
async def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/")
async def index():
    return {
        "service": "LAB723 inference",
        "model": MODEL_NAME,
        "endpoints": ["POST /predict", "GET /predict?text=...", "GET /healthz", "GET /ready", "GET /metrics"],
    }
