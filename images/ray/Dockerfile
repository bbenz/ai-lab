# The Ray head and workers for Exercise 5: Ray, ONNX Runtime, the model, and the batch code. Build from the
# repository root:
#   docker build -f images/ray/Dockerfile -t lab723/ray:1.0.0 .
# Keep the Ray version and the Python minor version the same as the notebook image's, which connects as a Ray client.
FROM rayproject/ray:2.59.0-py312-cpu

ENV RAY_USAGE_STATS_ENABLED=0 \
    PYTHONPATH=/home/ray/lab723 \
    LAB723_MODEL_DIR=/home/ray/model

RUN pip install --no-cache-dir onnxruntime==1.31.0 tokenizers==0.23.3

COPY --chown=1000:100 model/model.json app/model/fetch_model.py /tmp/model-fetch/
RUN python /tmp/model-fetch/fetch_model.py /tmp/model-fetch/model.json /home/ray/model && rm -rf /tmp/model-fetch

COPY --chown=1000:100 app/common/samples.py app/ray/lab723_batch.py /home/ray/lab723/
