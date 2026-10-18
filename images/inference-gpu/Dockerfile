# The inference service, on an NVIDIA GPU. Build from the repository root:
#   docker build -f images/inference-gpu/Dockerfile -t lab723/inference-gpu:1.0.0 .
# CUDA and cuDNN come from NVIDIA's Python packages, which onnxruntime-gpu[cuda,cudnn] installs. On an AKS GPU node,
# the device plugin gives the pod its GPU, and the NVIDIA container runtime adds the driver and, because of
# NVIDIA_DRIVER_CAPABILITIES, nvidia-smi. The image doesn't set NVIDIA_VISIBLE_DEVICES, so a pod that doesn't
# request a GPU doesn't see one.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    INFERENCE_DEVICE=cuda \
    MODEL_CACHE_DIR=/tmp/model \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    OTEL_SERVICE_NAME=inference-gpu \
    OTEL_PYTHON_FASTAPI_EXCLUDED_URLS="healthz,ready,metrics"

WORKDIR /app
COPY app/inference/requirements-gpu.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt
COPY app/inference/server.py /app/server.py

RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin app
USER 10001
EXPOSE 8080
CMD ["python", "-m", "uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8080", "--no-access-log"]
