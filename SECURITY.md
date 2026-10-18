# Security

## Reporting a vulnerability

Report security issues in this repository to the repository owner. For Microsoft products and services, follow the
[Microsoft Security Response Center](https://msrc.microsoft.com/create-report) process instead of opening a public issue.

Report vulnerabilities in the upstream projects that the lab uses to their own maintainers, such as
[Ray](https://github.com/ray-project/ray/security/advisories), [ONNX Runtime](https://github.com/microsoft/onnxruntime/security),
and [Jupyter](https://jupyter.org/security).

## What this content is

The lab runs in a temporary, single-attendee environment that's deleted when the lab ends. The design assumes a trusted
attendee and trusted code:

- **JupyterLab runs without a token.** Its Service has no ingress or load balancer, so it's reachable only through
  `kubectl port-forward`, which needs the attendee's Kubernetes permissions. Don't expose it any other way.
- **The Ray cluster isn't a security boundary.** Anyone who can reach the Ray head's client port or dashboard can run
  code on the cluster. Both are reachable only inside the cluster and through `kubectl port-forward`.
- **No secrets are stored in the cluster for the model.** The inference pods read the model from Azure Blob Storage with
  workload identity. The only secret is the Application Insights connection string, which the life cycle action puts
  in the `appinsights` Secret.
- **The images run as non-root users,** and the inference images don't include build tools. The GPU image doesn't set
  `NVIDIA_VISIBLE_DEVICES`, so only pods that request a GPU see one.

Don't include cluster names, subscription IDs, Temporary Access Passes, tokens, connection strings, or kubeconfig files
in issues or pull requests.
