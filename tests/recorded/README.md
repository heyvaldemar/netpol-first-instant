# Recorded runs

The first of the twenty fresh clusters per network plugin from run [43749621483](https://github.com/heyvaldemar/netpol-first-instant/actions/runs/43749621483): artifacts `result-kindnet-1`, `result-calico-1`, `result-cilium-1` and `result-kindnet-gvisor-1`, as `run.sh` wrote them on 2026-11-15.

Only the files `summarize.py` reads are kept: `env.txt`, `settled.tries`, `watch.log`, the `*.created` times, the gates' logs and, for kindnet, kindnet's own log (`cni.log.gz`) for its sync times. The probes' logs are gzipped and otherwise unchanged; `summarize.py` reads either form. Left out: the pods' full status, the server's connection log and the Calico manifest.

`expected.json` is what `summarize.py` counted here. `tests/check_recorded.py` counts again on every push and pull request and must get the same, and each change it plants in a copy must change the count.
