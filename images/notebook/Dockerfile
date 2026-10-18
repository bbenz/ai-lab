# JupyterLab with the Ray batch notebooks for Exercise 5. Build from the repository root:
#   docker build -f images/notebook/Dockerfile -t lab723/notebook:1.0.0 .
# It's based on the same Ray image as the cluster, because a Ray client needs the same Ray and Python versions. The
# prepare life cycle action sets RAY_ADDRESS to the Ray head's client port, and exposes JupyterLab only through
# kubectl port-forward, so it runs without a token.
FROM rayproject/ray:2.59.0-py312-cpu

ENV RAY_USAGE_STATS_ENABLED=0 \
    PYTHONPATH=/home/ray/lab723 \
    LAB723_MODEL_DIR=/home/ray/model

RUN pip install --no-cache-dir jupyterlab==4.6.4 ipykernel==7.4.0 ipywidgets==8.1.9 matplotlib==3.11.2 \
    onnxruntime==1.31.0 tokenizers==0.23.3

COPY --chown=1000:100 app/common/samples.py app/ray/lab723_batch.py /home/ray/lab723/
COPY --chown=1000:100 notebooks/ /home/ray/notebooks/

WORKDIR /home/ray/notebooks
EXPOSE 8888
CMD ["jupyter", "lab", "--ip=0.0.0.0", "--port=8888", "--no-browser", "--ServerApp.root_dir=/home/ray/notebooks", \
     "--IdentityProvider.token=", "--ServerApp.password=", "--ServerApp.allow_remote_access=True", \
     "--LabApp.news_url=None", "--LabApp.check_for_updates_class=jupyterlab.NeverCheckForUpdate"]
