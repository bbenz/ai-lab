"""Offline checks that keep the lab content consistent with the lab steps and the prepare life cycle action.

Run them from the repository root:
    python -m pip install -r tests/requirements.txt
    python -m pytest
"""

import json
import pathlib
import re
import sys

import pytest
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
LABFILES = ROOT / "labfiles"
sys.path[:0] = [str(ROOT / "app" / "common"), str(ROOT / "app" / "lab-client")]

import labclient  # noqa: E402
import samples  # noqa: E402


def documents(path):
    return [doc for doc in yaml.safe_load_all(path.read_text(encoding="utf-8")) if doc]


def all_documents():
    return [(path, doc) for path in sorted(LABFILES.rglob("*.yaml")) for doc in documents(path) if "kind" in doc]


def containers(doc):
    return doc["spec"]["template"]["spec"]["containers"]


def test_the_deny_demo_has_exactly_one_latest_tag():
    # The readiness gate checks for exactly one :latest line, which attendees replace in Exercise 2.
    text = (LABFILES / "02-deploy" / "inference-deployment.yaml").read_text(encoding="utf-8")
    assert len([line for line in text.splitlines() if ":latest" in line]) == 1
    others = [p for p in LABFILES.rglob("*.yaml") if p.name != "inference-deployment.yaml" or "02-deploy" not in str(p)]
    assert not [p for p in others if ":latest" in p.read_text(encoding="utf-8")]


def test_only_the_registry_placeholder_is_used():
    # The prepare LCA replaces these four placeholders, and the readiness gate fails on any that are left.
    found = set()
    for path in LABFILES.rglob("*.yaml"):
        found |= set(re.findall(r"<[a-z-]+>", path.read_text(encoding="utf-8")))
    assert found == {"<registry>"}


def test_every_container_has_probes_and_a_versioned_image():
    for path, doc in all_documents():
        if doc["kind"] != "Deployment":
            continue
        for container in containers(doc):
            assert container.get("readinessProbe") and container.get("livenessProbe"), f"{path}: {container['name']}"
            image = container["image"]
            assert image.startswith("<registry>/lab723/"), f"{path}: {image}"
            if "02-deploy" not in str(path) or "guardrails" in str(path):
                assert image.endswith(":1.0.0"), f"{path}: {image}"


def test_only_the_guardrail_demo_omits_resources():
    for path, doc in all_documents():
        if doc["kind"] == "Deployment":
            for container in containers(doc):
                has_resources = bool(container.get("resources", {}).get("limits"))
                assert has_resources == (doc["metadata"]["name"] != "guardrail-demo"), path


def test_services_have_unique_selectors_and_the_scraped_port_name():
    selectors = {}
    for _, doc in all_documents():
        if doc["kind"] == "Service":
            selectors.setdefault(json.dumps(doc["spec"]["selector"], sort_keys=True), set()).add(doc["metadata"]["name"])
            # The prepare LCA's ServiceMonitor scrapes Services labeled app: inference or inference-gpu on port "http".
            assert doc["metadata"]["labels"]["app"] in ("inference", "inference-gpu")
            assert [port["name"] for port in doc["spec"]["ports"]] == ["http"]
    assert all(len(names) == 1 for names in selectors.values()), selectors


@pytest.mark.parametrize("profile, cpu, threads", [("undersized", "500m", "1"), ("balanced", "1", "1"), ("large", "2", "2")])
def test_profiles_change_only_cpu_and_threads(profile, cpu, threads):
    patch = documents(LABFILES / "03-optimize" / "profiles" / f"{profile}.yaml")[0]
    container = patch["spec"]["template"]["spec"]["containers"][0]
    assert container["name"] == "inference"
    assert {env["name"]: env["value"] for env in container["env"]} == {"OMP_NUM_THREADS": threads, "INFERENCE_THREADS": threads}
    assert container["resources"] == {"requests": {"cpu": cpu, "memory": "2Gi"}, "limits": {"cpu": cpu, "memory": "2Gi"}}


def test_the_balanced_profile_matches_the_deployment():
    deployment = documents(LABFILES / "02-deploy" / "inference-deployment.yaml")[0]
    container = containers(deployment)[0]
    balanced = documents(LABFILES / "03-optimize" / "profiles" / "balanced.yaml")[0]["spec"]["template"]["spec"]["containers"][0]
    assert container["env"] == balanced["env"]
    assert container["resources"] == balanced["resources"]


def test_the_gpu_deployment_targets_the_gpu_node_pool():
    doc = documents(LABFILES / "03-optimize" / "inference-gpu.yaml")[0]
    spec = doc["spec"]["template"]["spec"]
    assert spec["nodeSelector"] == {"karpenter.sh/nodepool": "gpu"}
    assert spec["tolerations"][0]["key"] == "nvidia.com/gpu"
    assert containers(doc)[0]["resources"]["limits"]["nvidia.com/gpu"] == 1


def test_the_autoscaler_matches_the_lab_steps():
    hpa = documents(LABFILES / "04-scale" / "hpa.yaml")[0]["spec"]
    assert (hpa["minReplicas"], hpa["maxReplicas"]) == (1, 4)
    assert hpa["metrics"][0]["resource"]["target"]["averageUtilization"] == 60
    assert hpa["behavior"]["scaleDown"]["stabilizationWindowSeconds"] == 30


def test_checkpoints_are_compliant_and_reset_the_right_workloads():
    for folder in ("ex3", "ex4", "ex5"):
        docs = [doc for path in (LABFILES / "checkpoints" / folder).glob("*.yaml") for doc in documents(path)]
        inference = next(doc for doc in docs if doc["kind"] == "Deployment" and doc["metadata"]["name"] == "inference")
        assert containers(inference)[0]["image"] == "<registry>/lab723/inference:1.0.0"
        assert "replicas" not in inference["spec"], "The autoscaler owns the inference replica count."
    ex5 = {doc["metadata"]["name"]: doc for path in (LABFILES / "checkpoints" / "ex5").glob("*.yaml")
           for doc in documents(path) if doc["kind"] == "Deployment"}
    assert ex5["loadgen"]["spec"]["replicas"] == 0
    assert ex5["inference-gpu"]["spec"]["replicas"] == 0


def test_the_model_manifest_is_pinned():
    manifest = json.loads((ROOT / "model" / "model.json").read_text(encoding="utf-8"))
    assert [item["name"] for item in manifest["files"]] == ["model.onnx", "tokenizer.json", "config.json"]
    for item in manifest["files"]:
        assert re.fullmatch(r"[0-9a-f]{64}", item["sha256"])
        assert f"/resolve/{manifest['revision']}/" in item["url"]


def notebook(name):
    return json.loads((ROOT / "notebooks" / name).read_text(encoding="utf-8"))


def test_the_notebook_has_the_five_cells_that_the_lab_steps_describe():
    nb = notebook("ray-batch-inference.ipynb")
    code = [cell for cell in nb["cells"] if cell["cell_type"] == "code"]
    assert [cell["id"] for cell in code] == ["connect", "prepare", "one-worker", "all-workers", "compare"]
    assert all(not cell["outputs"] for cell in code), "Save the notebook without outputs."
    headings = [cell["source"][0] for cell in nb["cells"] if cell["cell_type"] == "markdown"][1:]
    assert headings == ["## 1. Connect\n", "## 2. Prepare\n", "## 3. Run on one worker\n",
                        "## 4. Run across all workers\n", "## 5. Compare\n"]


def test_the_example_output_is_labeled_and_matches_the_notebook():
    nb, example = notebook("ray-batch-inference.ipynb"), notebook("ray-batch-inference-EXAMPLE-OUTPUT.ipynb")
    assert "".join(example["cells"][0]["source"]).startswith("> **Example output.**")
    assert [c["source"] for c in example["cells"][1:]] == [c["source"] for c in nb["cells"]]
    outputs = [o for c in example["cells"] if c["cell_type"] == "code" for o in c["outputs"]]
    assert outputs and not [o for o in outputs if o["output_type"] == "error"]
    assert any("image/png" in o.get("data", {}) for o in outputs), "The Compare cell's chart is missing."


def test_the_dashboard_has_the_panels_that_the_lab_steps_describe():
    dashboard = json.loads((ROOT / "dashboard" / "lab723-ai-inference.json").read_text(encoding="utf-8"))
    assert dashboard["title"] == "LAB723 - AI inference"
    titles = " | ".join(panel["title"] for panel in dashboard["panels"])
    for words in ("Request rate", "Latency", "CPU use", "CPU throttling", "Replicas", "Nodes", "GPU utilization"):
        assert words in titles
    for panel in dashboard["panels"]:
        assert panel["datasource"]["uid"] == "${datasource}"


def test_samples_are_stable():
    assert len(samples.SAMPLES) == len(set(samples.SAMPLES)) == 40
    assert samples.make_batch(50) == samples.make_batch(50)
    assert len(samples.make_batch(1000)) == 1000


def test_lab_client_helpers():
    assert labclient.predict_url("inference") == "http://inference/predict"
    assert labclient.predict_url("inference-gpu:8080") == "http://inference-gpu:8080/predict"
    assert labclient.predict_url("http://example.com/custom") == "http://example.com/custom"
    values = sorted(float(v) for v in range(1, 101))
    assert labclient.percentile(values, 50) == pytest.approx(50.5)
    assert labclient.percentile(values, 95) == pytest.approx(95.05)
    assert labclient.percentile([7.0], 99) == 7.0


def test_images_pin_their_versions():
    for dockerfile in (ROOT / "images").glob("*/Dockerfile"):
        text = dockerfile.read_text(encoding="utf-8").replace("\\\n", " ")
        assert re.search(r"^FROM \S+:\S+", text, re.MULTILINE), dockerfile
        for command in re.findall(r"pip install ([^\n&]*)", text):
            tokens = iter(command.split())
            for token in tokens:
                if token == "-r":
                    next(tokens)  # A requirements file, which pins its own versions
                elif not token.startswith("-"):
                    assert "==" in token, f"{dockerfile.parent.name}: {token} isn't pinned"
    for requirements in (ROOT / "app" / "inference").glob("requirements*.txt"):
        for line in requirements.read_text(encoding="utf-8").splitlines():
            if line.strip() and not line.startswith("#"):
                assert "==" in line, f"{requirements.name}: {line}"
