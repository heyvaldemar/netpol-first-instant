# netpol-first-instant

A measurement, not a tool: does a pod's NetworkPolicy hold from the pod's very
first instant? Each run is a fresh [kind](https://kind.sigs.k8s.io/) cluster
with one network plugin (kindnet, with the pods on runc or on gVisor, Calico or
Cilium), a namespace whose policy allows no egress but one canary, and pods
whose entrypoint sends from the first millisecond to a server on the runner and
to `1.1.1.1:80`.

- `probe/` the probe: one static Go binary in an empty image.
- `run.sh` one run; `summarize.py` counts what answered.
- `tests/recorded/` one recorded run per network plugin, which `tests/check_recorded.py` counts again on every push (the Verify workflow).
- `.github/workflows/measure.yml` runs the matrix on demand:

```bash
gh workflow run measure.yml
```

Results are the workflow runs' artifacts and summaries.
