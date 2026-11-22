#!/usr/bin/env bash
# One measurement on a fresh kind cluster with one network plugin.
#
#   ./run.sh kindnet|kindnet-gvisor|calico|cilium
#
# Namespace `probe` allows no egress but TCP 8080 to a canary pod. Once a
# settled pod there is provably blocked (so the plugin has handled the
# policy, as the Kubernetes docs require before their promise applies),
# PODS new pods are started one after another, each sending from its first
# instant to a server on the runner (outside the cluster) every 10 ms and to
# 1.1.1.1:80 every 50 ms. GATED more pods wait at an init container that lets
# them start only once the canary answers and the runner's server does not.
# A pod in `control`, with no policy, shows what an unblocked pod gets.
#
# Everything lands in $OUT; summarize.py reads it.
set -euo pipefail

CNI="${1:?usage: run.sh kindnet|kindnet-gvisor|calico|cilium}"
PODS="${PODS:-10}"
GATED="${GATED:-5}"
# Inputs reach paths and shell arithmetic: only known names and plain numbers.
case "$CNI" in kindnet | kindnet-gvisor | calico | cilium) ;; *) echo "unknown CNI: $CNI" >&2; exit 2 ;; esac
case "$PODS$GATED" in *[!0-9]*) echo "PODS and GATED must be whole numbers" >&2; exit 2 ;; esac
case "${OUT:-}" in *..* | /* | *[!A-Za-z0-9._/-]*) echo "OUT must be a relative path inside the checkout" >&2; exit 2 ;; esac
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mkdir -p "$ROOT/${OUT:-out/$CNI}" && cd "$ROOT/${OUT:-out/$CNI}" && pwd)"
CLUSTER=probe
IMAGE=netpol-probe:local

log() { printf '%s %s\n' "$(date -u +%H:%M:%S.%3N)" "$*"; }

# kindnet-gvisor is kindnet with the probe pods on gVisor, as the agents run
# in kubernetes-ai-agent-sandbox and kubernetes-coder-agent-workspaces.
RUNTIME=runc
if [ "$CNI" = kindnet-gvisor ]; then RUNTIME=gvisor; fi
export RUNTIME

# --- tools, pinned by sha256 ---------------------------------------------------
BIN="$ROOT/.bin"
mkdir -p "$BIN"
export PATH="$BIN:$PATH"
fetch() {  # name url sha256; a cached copy is used only if its hash still matches
  if [ -x "$BIN/$1" ] && echo "$3  $BIN/$1" | sha256sum -c --quiet - 2>/dev/null; then return 0; fi
  curl -fsSL --retry 3 -o "$BIN/$1.part" "$2"
  echo "$3  $BIN/$1.part" | sha256sum -c --quiet -
  chmod +x "$BIN/$1.part"
  mv "$BIN/$1.part" "$BIN/$1"
}
fetch kind https://github.com/kubernetes-sigs/kind/releases/download/v0.33.0/kind-linux-amd64 \
  aee6151561422756b764a4ae28e7f44cda5af5a9eead3cc9985112b1de8d8e0d
fetch kubectl https://dl.k8s.io/release/v1.37.1/bin/linux/amd64/kubectl \
  65691ff77eb6fa44c908b77a1082c9f092c3b9733b5cefabec0d1104890e21a8

{
  echo "cni=$CNI runtime=$RUNTIME pods=$PODS gated=$GATED"
  echo "kernel=$(uname -r)"
  echo "os=$(grep -m1 "^PRETTY_NAME=" /etc/os-release | cut -d= -f2-)"
  echo "docker=$(docker version --format '{{.Server.Version}}')"
  kind version
  kubectl version --client | head -1
} > "$OUT/env.txt"
cat "$OUT/env.txt"

# kind on a GitHub runner needs more inotify instances than the default.
sudo sysctl -q -w fs.inotify.max_user_instances=1280 fs.inotify.max_user_watches=1048576 || true

# --- cluster and network plugin -------------------------------------------------
case "$CNI" in
  kindnet) cfg="$ROOT/kind/kindnet.yaml" ;;
  kindnet-gvisor) cfg="$ROOT/kind/kindnet-gvisor.yaml" ;;
  calico | cilium) cfg="$ROOT/kind/no-cni.yaml" ;;
  *) echo "unknown CNI $CNI" >&2; exit 2 ;;
esac
log "creating the cluster ($CNI)"
kind create cluster --config "$cfg" --name "$CLUSTER" --wait 0s

case "$CNI" in
  calico)
    curl -fsSL --retry 3 -o "$OUT/calico.yaml" https://raw.githubusercontent.com/projectcalico/calico/v3.33.0/manifests/calico.yaml
    echo "2de8f47595fb9c41b3f47d7b767a1f8e72ecf84057af834738ff12689a234da5  $OUT/calico.yaml" | sha256sum -c --quiet -
    # One node, so no encapsulation; the pool is kind's pod subnet; and a
    # GitHub runner's rp_filter is loose, which Felix refuses to run with
    # unless told to ignore it.
    cidr="$(kubectl -n kube-system get configmap kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' | awk '$1 == "podSubnet:" {print $2}')"
    python3 - "$OUT/calico.yaml" "$cidr" > "$OUT/calico-kind.yaml" <<'PY'
import re, sys
t, cidr = open(sys.argv[1]).read(), sys.argv[2]
assert "/" in cidr, cidr
t, n1 = re.subn(r'(- name: CALICO_IPV4POOL_IPIP\n(\s+)value: )"Always"', r'\1"Never"', t)
t, n2 = re.subn(r'(\n(\s+)- name: FELIX_HEALTHENABLED\n\s+value: "true")',
                r'\1\n\2- name: FELIX_IGNORELOOSERPF\n\2  value: "true"', t)
t, n3 = re.subn(r'# (- name: CALICO_IPV4POOL_CIDR)\n(\s+)#   value: "[^"]*"',
                r'\1\n\2  value: "' + cidr + '"', t)
assert n1 == 1 and n2 == 1 and n3 == 1, (n1, n2, n3)
sys.stdout.write(t)
PY
    kubectl apply -f "$OUT/calico-kind.yaml" >/dev/null
    kubectl -n kube-system rollout status ds/calico-node --timeout=8m
    kubectl -n kube-system rollout status deploy/calico-kube-controllers --timeout=8m
    ;;
  cilium)
    # Pinned at 1.20.4 on purpose. Cilium 1.20.5 (22 November 2026) closes a hole in
    # CiliumNetworkPolicy where toServices together with toPorts let egress go anywhere.
    # This repository applies only Kubernetes NetworkPolicy (default-deny and
    # to-the-canary below), never a CiliumNetworkPolicy, so that path is not exercised;
    # the recorded runs in tests/recorded/cilium-1 were taken on 1.20.4 and stay comparable.
    curl -fsSL --retry 3 -o "$OUT/cilium-1.20.4.tgz" https://helm.cilium.io/cilium-1.20.4.tgz
    echo "505abff8385811df1a949776fc42e9f10697989a332acc86d6e8933efcb855ed  $OUT/cilium-1.20.4.tgz" | sha256sum -c --quiet -
    helm version --short >> "$OUT/env.txt"
    helm install cilium "$OUT/cilium-1.20.4.tgz" --namespace kube-system \
      --set ipam.mode=kubernetes --set image.pullPolicy=IfNotPresent --set operator.replicas=1 \
      --wait --timeout 8m >/dev/null
    kubectl -n kube-system rollout status ds/cilium --timeout=8m
    rm -f "$OUT/cilium-1.20.4.tgz"
    ;;
esac
if [ "$RUNTIME" = gvisor ]; then
  # The release and its SHA-512 are kubernetes-ai-agent-sandbox's gvisor.lock.
  curl -fsSL --retry 3 -o "$OUT/gvisor.tar.bz2" https://storage.googleapis.com/gvisor/releases/release/20261012/x86_64/gvisor.tar.bz2
  echo "9606445eed5aedfcf05310e7ccef61d994089914c6622fc82624c24d2b18db1b2210f40e40a7be27b8b7772859de7d95c501b4eba66423053c960bf671377c5e  $OUT/gvisor.tar.bz2" | sha512sum -c --quiet -
  mkdir -p "$OUT/gvisor" && tar -xjf "$OUT/gvisor.tar.bz2" -C "$OUT/gvisor" runsc containerd-shim-runsc-v1 gvisor-bin
  node="$(kind get nodes --name "$CLUSTER")"
  docker cp "$OUT/gvisor/runsc" "$node:/usr/local/bin/runsc"
  docker cp "$OUT/gvisor/containerd-shim-runsc-v1" "$node:/usr/local/bin/containerd-shim-runsc-v1"
  docker cp "$OUT/gvisor/gvisor-bin" "$node:/usr/local/bin/"
  docker exec "$node" sh -c 'printf "[runsc_config]\n  systemd-cgroup = \"true\"\n" > /etc/containerd/runsc.toml'
  docker exec "$node" sh -c 'chmod 755 /usr/local/bin/runsc /usr/local/bin/containerd-shim-runsc-v1 /usr/local/bin/gvisor-bin/* && systemctl restart containerd'
  echo "runsc=$(docker exec "$node" runsc --version | head -1)" >> "$OUT/env.txt"
  rm -rf "$OUT/gvisor" "$OUT/gvisor.tar.bz2"
  kubectl apply -f - >/dev/null <<'EOF'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata: {name: gvisor}
handler: runsc
EOF
fi
kubectl wait --for=condition=Ready node --all --timeout=6m
kubectl -n kube-system rollout status deploy/coredns --timeout=6m
kubectl -n kube-system get pods -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | sort -u > "$OUT/images.txt"
kubectl version | tail -1 >> "$OUT/env.txt"

# --- the probe image and the server outside the cluster -------------------------
docker build -q -t "$IMAGE" "$ROOT/probe" >/dev/null
kind load docker-image "$IMAGE" --name "$CLUSTER" >/dev/null
GW="$(docker network inspect kind | python3 -c '
import json, sys
print([c["Gateway"] for c in json.load(sys.stdin)[0]["IPAM"]["Config"] if "." in c.get("Gateway", "")][0])')"
docker rm -f outside >/dev/null 2>&1 || true
trap 'docker rm -f outside >/dev/null 2>&1 || true' EXIT
docker run -d --name outside --network host -e PROBE_LISTEN="$GW:18080" "$IMAGE" serve >/dev/null
OUTSIDE="$GW:18080"
INTERNET="1.1.1.1:80"
log "outside the cluster: $OUTSIDE (the runner) and $INTERNET"

# --- namespaces and policies -----------------------------------------------------
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Namespace
metadata: {name: canary}
---
apiVersion: v1
kind: Namespace
metadata: {name: probe}
---
apiVersion: v1
kind: Namespace
metadata: {name: control}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: default-deny, namespace: probe}
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: to-the-canary, namespace: probe}
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels: {kubernetes.io/metadata.name: canary}
          podSelector:
            matchLabels: {app: canary}
      ports:
        - {protocol: TCP, port: 8080}
EOF
date +%s%N > "$OUT/policy.applied"

# pod NAME NAMESPACE MODE GATED [TARGETS]
pod() {
  python3 - "$@" <<'PY'
import json, os, sys
name, ns, mode, gated = sys.argv[1:5]
targets = sys.argv[5] if len(sys.argv) > 5 else os.environ["TARGETS"]
sec = {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True, "capabilities": {"drop": ["ALL"]}}
res = {"requests": {"cpu": "50m", "memory": "16Mi"}, "limits": {"cpu": "1", "memory": "64Mi"}}
podname = {"name": "POD_NAME", "valueFrom": {"fieldRef": {"fieldPath": "metadata.name"}}}
spec = {
    "restartPolicy": "Never", "terminationGracePeriodSeconds": 1,
    **({"runtimeClassName": "gvisor"} if os.environ["RUNTIME"] == "gvisor" and name != "canary" else {}),
    "automountServiceAccountToken": False, "enableServiceLinks": False,
    "securityContext": {"runAsNonRoot": True, "runAsUser": 65532, "runAsGroup": 65532,
                        "seccompProfile": {"type": "RuntimeDefault"}},
    "containers": [{
        "name": "probe", "image": os.environ["IMAGE"], "imagePullPolicy": "Never", "args": [mode],
        "env": [podname, {"name": "PROBE_TARGETS", "value": targets}, {"name": "PROBE_HOLD", "value": "outside"}],
        "resources": res, "securityContext": sec}],
}
if gated == "1":
    spec["initContainers"] = [{
        "name": "gate", "image": os.environ["IMAGE"], "imagePullPolicy": "Never", "args": ["gate"],
        "env": [podname, {"name": "GATE_ALLOW", "value": os.environ["CANARY"]},
                {"name": "GATE_DENY", "value": os.environ["OUTSIDE"]}],
        "resources": res, "securityContext": sec}]
labels = {"app": "canary"} if name == "canary" else {"app": "probe"}
if name == "canary":
    spec["containers"][0]["ports"] = [{"containerPort": 8080}]
print(json.dumps({"apiVersion": "v1", "kind": "Pod",
                  "metadata": {"name": name, "namespace": ns, "labels": labels}, "spec": spec}))
PY
}
export IMAGE OUTSIDE
export TARGETS="outside=echo:$OUTSIDE@10,internet=http:$INTERNET@50"

pod canary canary serve 0 "x=echo:127.0.0.1:1" | kubectl apply -f - >/dev/null
kubectl -n canary wait --for=condition=Ready pod/canary --timeout=3m >/dev/null
CANARY="$(kubectl -n canary get pod canary -o jsonpath='{.status.podIP}'):8080"
export CANARY
log "canary: $CANARY"

# --- the policy must be handled before the docs' promise applies -----------------
log "waiting until a settled pod in probe is blocked"
pod settled probe idle 0 "outside=echo:$OUTSIDE,internet=http:$INTERNET,canary=echo:$CANARY" | kubectl apply -f - >/dev/null
kubectl -n probe wait --for=condition=Ready pod/settled --timeout=3m >/dev/null
settled=""
for i in $(seq 1 45); do
  kubectl -n probe exec settled -- /probe once > "$OUT/settled.log" 2>&1 || true
  if python3 - "$OUT/settled.log" <<'PY'
import json, sys
r = {a["target"]: a["result"] for l in open(sys.argv[1]) if l.startswith("{")
     for d in [json.loads(l)] if d.get("event") == "once" for a in d["attempts"]}
ok = lambda t: r.get(t) in ("reply", "connected")
sys.exit(0 if r and not ok("outside") and not ok("internet") and ok("canary") else 1)
PY
  then settled="$i"; break; fi
  sleep 2
done
kubectl -n probe delete pod settled --wait=true >/dev/null
if [ -z "$settled" ]; then
  log "INVALID: the settled pod was never blocked (or never reached the canary)"
  echo invalid > "$OUT/verdict"
fi
echo "${settled:-never}" > "$OUT/settled.tries"

# --- pods that send from their first instant ---------------------------------------
( kubectl get pods -n probe --watch --output-watch-events \
    -o jsonpath='{.type}{" "}{.object.metadata.name}{" "}{.object.status.podIP}{" "}{.object.status.phase}{"\n"}' 2>/dev/null |
  while IFS= read -r l; do printf '%s %s\n' "$(date +%s%N)" "$l"; done > "$OUT/watch.log" ) &
WATCH=$!
sleep 2

run_pod() {  # name namespace gated
  local name="$1" ns="$2" gated="$3" phase=""
  date +%s%N > "$OUT/$name.created"
  pod "$name" "$ns" probe "$gated" | kubectl apply -f - >/dev/null
  for _ in $(seq 1 120); do
    phase="$(kubectl -n "$ns" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "$phase" in Succeeded | Failed) break ;; esac
    sleep 1
  done
  kubectl -n "$ns" logs "$name" -c probe > "$OUT/$name.log" 2>&1 || true
  if [ "$gated" = 1 ]; then kubectl -n "$ns" logs "$name" -c gate > "$OUT/$name.gate.log" 2>&1 || true; fi
  kubectl -n "$ns" get pod "$name" -o json > "$OUT/$name.pod.json" 2>/dev/null || true
  kubectl -n "$ns" delete pod "$name" --wait=true >/dev/null 2>&1 || true
  log "$ns/$name: $phase"
}

run_pod control-1 control 0
n=0; g=0
total=$((PODS + GATED))
for i in $(seq 1 "$total"); do
  # Spread the gated pods among the others: every third pod while both remain.
  if [ "$g" -lt "$GATED" ] && { [ $((i % 3)) -eq 0 ] || [ "$n" -ge "$PODS" ]; }; then
    g=$((g + 1)); run_pod "gated-$g" probe 1
  else
    n=$((n + 1)); run_pod "first-$n" probe 0
  fi
done
kill "$WATCH" 2>/dev/null || true

# --- what the plugin itself logged --------------------------------------------------
case "$CNI" in
  kindnet | kindnet-gvisor) kubectl -n kube-system logs ds/kindnet --timestamps > "$OUT/cni.log" 2>&1 || true ;;
  calico) kubectl -n kube-system logs ds/calico-node -c calico-node --timestamps --tail=5000 > "$OUT/cni.log" 2>&1 || true ;;
  cilium) kubectl -n kube-system logs ds/cilium -c cilium-agent --timestamps --tail=5000 > "$OUT/cni.log" 2>&1 || true ;;
esac
docker logs outside > "$OUT/outside.log" 2>&1 || true
gzip -f "$OUT/cni.log" "$OUT/outside.log"
rm -f "$OUT/calico.yaml" "$OUT/calico-kind.yaml"

python3 "$ROOT/summarize.py" "$OUT"
