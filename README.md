# LAB723: Build, observe, and scale AI-ready apps

The lab content for Microsoft Ignite 2026 lab LAB723, which runs on Azure Kubernetes Service (AKS) Automatic in a
Skillable-hosted environment: the sample app's six container images, the Kubernetes manifests that attendees apply,
the Ray notebook, and the monitoring dashboard.

The Azure environment itself, including the cluster, the registry, the storage, and the monitoring, comes from the lab's
Terraform configuration and life cycle actions (LCAs), which aren't in this repository.

## Contents

| Path | Contents |
| --- | --- |
| `app/inference` | The inference service: a compact sentiment model on ONNX Runtime, behind FastAPI. It loads the model from Azure Blob Storage with workload identity, reports its own latency, serves Prometheus metrics at `/metrics`, and sends OpenTelemetry traces to Application Insights. |
| `app/lab-client` | The `predict` and `bench` commands that attendees run with `kubectl exec`. Python standard library only. |
| `app/loadgen` | The load generator for the autoscaling exercise. Python standard library only. |
| `app/ray` | The batch code that the Ray workers run for the notebook. |
| `app/common` | Sample reviews, written for this lab, that the client, the load generator, and the notebook send. |
| `app/model` | A downloader that checks each model file's SHA-256 hash. |
| `images` | A Dockerfile for each image. Build them from the repository root. |
| `labfiles` | The manifests that the lab VM has in `C:\LabFiles\LAB723`: `02-deploy`, `03-optimize`, `04-scale`, and `checkpoints`. |
| `notebooks` | `ray-batch-inference.ipynb`, and a saved copy of a completed run that's labeled as example output. |
| `dashboard` | `lab723-ai-inference.json`, the **LAB723 - AI inference** Grafana dashboard. |
| `model/model.json` | The model's source, pinned revision, license, files, and SHA-256 hashes. The model isn't stored in this repository. |
| `setup/Install-LabContent.ps1` | Installs this content into a running lab, to test the lab steps. |
| `local/compose.yaml` | Runs the workloads on Docker, without Azure. |
| `tests` | Offline checks that keep the content consistent with the lab steps and the LCAs. |

## The images

The LCAs expect each image at `<registry>/lab723/<name>:1.0.0`.

| Image | Based on | What it runs |
| --- | --- | --- |
| `inference` | `python:3.12-slim` | The inference service on the CPU, with ONNX Runtime 1.31. The thread count comes from `INFERENCE_THREADS` or `OMP_NUM_THREADS`, which each Exercise 3 profile sets to match its CPU limit. One prediction runs at a time, so the latency under load includes the time requests wait. |
| `inference-gpu` | `python:3.12-slim` | The same service on an NVIDIA GPU, with ONNX Runtime 1.26, the newest version built for CUDA 12, which runs with NVIDIA drivers from the 525 series on. If the pod gets no GPU, it runs on the CPU and logs an error. |
| `lab-client` | `python:3.12-slim` | `predict` and `bench`. The LCA runs it with `sleep infinity`. The guardrail demo in Exercise 2 uses it too. |
| `loadgen` | `python:3.12-slim` | Eight workers that send predictions to `TARGET_URL` until the pod stops. Each request uses a new connection, so the load spreads across new replicas. |
| `ray` | `rayproject/ray:2.59.0-py312-cpu` | The Ray head and workers, with ONNX Runtime, the model files, and the batch code |
| `notebook` | `rayproject/ray:2.59.0-py312-cpu` | JupyterLab with the two notebooks. It connects to the Ray cluster as a Ray client, which needs the same Ray and Python versions as the cluster. It has no token, because it's reachable only through `kubectl port-forward`. |

Every image runs as a non-root user and includes `sh`, which the LCA's image pre-puller runs.

## Use it in the lab

### Publish the images

The `Publish the lab images` workflow builds the six images and pushes them to GitHub Container Registry as
`ghcr.io/<owner>/lab723/<name>:<tag>`. Push a tag to run it:

```powershell
git tag v1.0.0
git push origin v1.0.0
```

The tag `v1.0.0` publishes the image tag `1.0.0`, and attaches `lab723-labfiles.zip`, the contents of `labfiles`, to the
release. You can also run the workflow from the **Actions** tab with a tag of your choice.

The first time, make each of the six packages public: on GitHub, open the package, select **Package settings**, and set
**Change visibility** to **Public**. The LCA imports them without credentials.

### Set up the event's lab profile

1. In the prepare LCA's settings, set `SourceRegistry` to `ghcr.io/<owner>`. The LCA imports the images into each lab's
   registry.
2. When you build the lab VM image, put the lab files and the model in it. In the VM, in PowerShell as administrator:

    ```powershell
    git clone https://github.com/bbenz/ai-lab C:\LabSetup\ai-lab
    Set-ExecutionPolicy Bypass -Scope Process -Force
    C:\LabSetup\ai-lab\setup\Install-LabContent.ps1 -FilesOnly
    ```

    That copies `labfiles` to `C:\LabFiles\LAB723`, and downloads the model to `C:\LabFiles\LAB723-model`, which the LCA
    uploads to each lab's storage account. Instead of the lab files in the image, you can set the LCA's `LabFilesZipUrl`
    to the release's `lab723-labfiles.zip`.

### Test the lab steps in a running lab

In a lab where the LAB723 begin state finished, open PowerShell as administrator, and run:

```powershell
git clone https://github.com/bbenz/ai-lab C:\LabSetup\ai-lab
Set-ExecutionPolicy Bypass -Scope Process -Force
C:\LabSetup\ai-lab\setup\Install-LabContent.ps1
```

The script copies the lab files, downloads the model, and puts the six images in the lab's registry: it imports the
ones that the workflow published, and builds the rest with ACR Tasks (`az acr build`), which takes 10 to 15 minutes.
Then it runs the begin state again, which deploys `lab-client`, `loadgen`, the notebook, and the Ray cluster with the lab
image, uploads the model, replaces `<registry>` in the lab files, and runs the readiness gate. Your Azure CLI must be
signed in with the lab account, as it is after the manual begin state. To import only, add `-ImageSource Import`.

### Import the dashboard

In the Azure portal, open the cluster. Under **Monitoring**, select **Dashboards with Grafana**, and then import
`dashboard/lab723-ai-inference.json`. Choose the lab's Azure Monitor workspace as the Prometheus data source.

The GPU utilization panel uses the DCGM exporter on AKS-managed GPU nodes. If it stays empty while the GPU pod runs,
check that `dcgmexporter = true` is under `default-targets-scrape-enabled` in the cluster's
`ama-metrics-settings-configmap` ([template](https://github.com/Azure/prometheus-collector/blob/main/otelcollector/configmaps/ama-metrics-settings-configmap.yaml)).
Metrics take a few minutes to arrive.

## The inference service

| Endpoint | Returns |
| --- | --- |
| `POST /predict` with `{"text": "..."}` | The label, score, device, pod, and the time that the server and the model spent, in milliseconds |
| `GET /predict?text=...` | The same, for a quick test in a browser |
| `GET /healthz` | The status, model, and device (`cpu` or `cuda`). The liveness probe. |
| `GET /ready` | 200 when the model is loaded. The readiness probe. |
| `GET /metrics` | Prometheus metrics |

| Metric | Type | Labels |
| --- | --- | --- |
| `lab723_inference_requests_total` | Counter | `device`, `outcome` |
| `lab723_inference_request_duration_seconds` | Histogram: the server's time, including waiting for the model | `device` |
| `lab723_inference_model_duration_seconds` | Histogram: the model's time | `device` |
| `lab723_inference_in_flight_requests` | Gauge | |
| `lab723_inference_model_load_seconds` | Gauge | |
| `lab723_inference_info` | Gauge, always 1 | `model`, `device`, `version` |

| Setting | Default | Meaning |
| --- | --- | --- |
| `MODEL_ACCOUNT_URL`, `MODEL_CONTAINER` | None, `models` | Where the model is. The `lab-environment` ConfigMap sets them. |
| `MODEL_PREFIX` | None | A folder in the container, if the files aren't at its root |
| `MODEL_LOCAL_DIR` | None | For testing: read the model from a folder instead of Blob Storage |
| `INFERENCE_DEVICE` | `cpu`, or `cuda` in the GPU image | Where the model runs |
| `INFERENCE_THREADS`, `OMP_NUM_THREADS` | `1` | The runtime's thread count |
| `INFERENCE_CONCURRENCY` | `1` | Predictions that run at the same time |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | None | Turns on OpenTelemetry to Application Insights. The `appinsights` Secret sets it. |

## Develop and test

Run the offline checks:

```powershell
python -m venv .venv
.\.venv\Scripts\python -m pip install -r tests/requirements.txt
.\.venv\Scripts\python -m pytest
```

Run the workloads on Docker, as described at the top of `local/compose.yaml`. To regenerate the example output notebook,
run `ray-batch-inference.ipynb` against the Compose stack, and save a copy with the outputs and the example-output banner.

## The model

[DistilBERT base uncased, fine-tuned on SST-2](https://huggingface.co/distilbert/distilbert-base-uncased-finetuned-sst-2-english),
which classifies English text as POSITIVE or NEGATIVE: the ONNX export at revision
`714eb0fa89d2f80546fda750413ed43d93601a13`, licensed under Apache-2.0. `model/model.json` pins each file's URL and SHA-256
hash. The Ray image downloads it at build time, and the install script downloads it for the lab VM.

## Third-party software

| Component | License | Used in |
| --- | --- | --- |
| DistilBERT SST-2 model (Hugging Face) | Apache-2.0 | The model files |
| ONNX Runtime | MIT | `inference`, `inference-gpu`, `ray`, `notebook` |
| NVIDIA CUDA, cuDNN, and cuBLAS Python packages | NVIDIA software license | `inference-gpu` |
| Hugging Face Tokenizers | Apache-2.0 | `inference`, `inference-gpu`, `ray`, `notebook` |
| FastAPI, Uvicorn, Pydantic | MIT, BSD-3-Clause, MIT | `inference`, `inference-gpu` |
| Prometheus Python client | Apache-2.0 | `inference`, `inference-gpu` |
| Azure Identity, Azure Storage Blobs, and Azure Monitor OpenTelemetry for Python | MIT | `inference`, `inference-gpu` |
| Ray | Apache-2.0 | `ray`, `notebook` |
| JupyterLab, ipykernel, ipywidgets | BSD-3-Clause | `notebook` |
| Matplotlib | Matplotlib license (PSF-based) | `notebook` |
| Python, Debian base image | PSF, various | Every image |

## Contributing

This project welcomes contributions and suggestions. See [`SECURITY.md`](SECURITY.md) for how to report a security issue,
and [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md) for the code of conduct.
