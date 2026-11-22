# Security policy

## Supported versions

| Version | Supported |
|---|---|
| `main` | yes |

## Reporting a vulnerability

Report privately through GitHub: [**Security → Report a vulnerability**](https://github.com/heyvaldemar/netpol-first-instant/security/advisories/new) on this repository. Email to connect@valdemar.ai also works. The process is described at [heyvaldemar.com/security](https://heyvaldemar.com/security/).

You can expect an acknowledgment within 7 days. There is no bounty program; valid, responsibly disclosed reports are credited in the commit that fixes them. Please do not open public issues for security reports.

## What this repository is

A measurement, not a tool or a service: it creates kind clusters on GitHub's runners, measures them, and throws them away. A vulnerability here is most likely in its CI, a workflow that hands a token to code it should not run, or an input that reaches a shell or a path. A finding about a network plugin itself belongs with that plugin's project.

## Supply chain

- GitHub Actions are pinned by commit SHA; CI images by digest (`ci-images.pins`).
- `run.sh` refuses kind and kubectl whose sha256 differs from the one it names, the Calico manifest and the Cilium chart likewise, and the gVisor bundle by its SHA-512.
- The probe is built from `probe/` in a Go image pinned by digest, into an empty image.

## Credentials

None. Nothing in this repository or its CI stores a credential; the workflows use the run's own token with read access only, except the jobs that sign a release and merge Dependabot's updates.
