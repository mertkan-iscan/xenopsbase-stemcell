# ADR-0004: Argo CD reconciles the cluster from git

- **Status:** Accepted
- **Date:** 2026-08-18
- **Task:** T-0.5

## Context

ADR-0002 requires that a bare cluster converges to a complete platform with no human action. That
makes the GitOps engine the component the entire rebuild story runs through: if it does not install
itself cleanly and reconcile everything else, `make up` is not one command and the ephemeral model
does not hold.

The choice is between Argo CD and Flux. Both reconcile git to a cluster and both are mature; the
decision turns on which failure mode matters more in this specific setup.

The relevant asymmetry is that **rebuilds are frequent and unattended**, so convergence failures
are the routine failure of this project rather than a rare one. A rebuild that half-converges at
07:00 needs to be diagnosable quickly, by one person, without deep familiarity with whichever
component broke.

## Decision criteria

- **Bootstrap onto a bare cluster** — how much has to happen before the engine can take over
- **Diagnosability when convergence fails**, since this is the expected failure mode
- **Idle resource footprint**, on small Hetzner nodes where it competes with workloads
- **SOPS integration**, given ADR-0003

## Decision

**Argo CD**, installed by Terraform via the Helm provider, with a single root `Application`
pointing at this repository — the app-of-apps pattern. Everything else in the platform is a child
Application of that root.

SOPS decryption (ADR-0003) is provided by **KSOPS** as a plugin on `argocd-repo-server`, with the
age private key supplied as a Kubernetes Secret created by Terraform during bootstrap.

### Bootstrap sequence

```
terraform apply
  -> K3s cluster exists (T-1.3)
  -> Helm release: argo-cd, plus the age key Secret     <- the only imperative step
  -> root Application -> this repository
    -> child Applications: ingress, cert-manager, CloudNativePG, Keycloak, LGTM, ...
```

One imperative step, expressed in Terraform. Everything after it is declarative and reconciled.

## Consequences

### What this makes easy

- **Convergence failures are visible.** The UI shows sync status per Application, the diff between
  desired and live state, and the failing resource's events without hunting through CRD status
  fields. Given that unattended rebuilds are routine here, this is the property that decided it.
- The app-of-apps pattern is very well documented, which matters for a template that other
  projects inherit.
- Promotion between environments (T-6.3) maps cleanly onto Applications per environment.
- Drift is detected and reverted, which is what makes the "no state created by a human" rule of
  ADR-0002 structurally enforced rather than merely stated.

### What this makes hard

- **Heavier than the alternative.** `argocd-server`, `repo-server`, `application-controller`, Redis
  and Dex are several hundred MB of always-on memory while the cluster is up. On small nodes that
  competes directly with workloads, and it is the main cost of this choice. It does not affect idle
  cost, since idle means destroyed.
- **SOPS needs wiring.** KSOPS is a sidecar and a custom `repo-server` configuration. Flux decrypts
  SOPS natively with no extra moving parts. This is a fixed one-time cost paid in T-2.1 and T-2.3,
  and a component that can break a rebuild — it is the piece most likely to need debugging on an
  Argo CD upgrade.
- Argo CD's own configuration is state that must itself come from git, or it becomes exactly the
  hand-made state ADR-0002 forbids.

### What it commits us to

T-2.1 is written against this decision, and every platform component from T-2.2 onward ships as an
Argo CD Application. Switching to Flux later would mean re-expressing those manifests — a
mechanical change, since the underlying Helm charts and Kustomize bases are engine-agnostic, but
touching every platform task.

## Alternatives considered

### Flux — rejected, and it was close

Flux was the better fit on three of the four criteria. It is substantially lighter, which matters
on small nodes. `flux bootstrap` is purpose-built for the install-onto-a-bare-cluster problem.
Decisively on paper, it decrypts SOPS natively, making ADR-0003 a first-class supported path
instead of a sidecar to maintain.

It was rejected on diagnosability. Flux surfaces state through CRD conditions and `flux` CLI
output, which is efficient once fluent and slow when the failing component is unfamiliar. For a
solo operator facing frequent unattended rebuilds, being able to see at a glance *which* of twelve
Applications failed to sync and what the live-versus-desired diff is was judged worth both the
memory and the KSOPS wiring.

This is a preference-weighted call, not a technical verdict. The trade is explicit: **more
resident memory and one fragile integration, bought with faster diagnosis of the failure mode that
will actually happen.** If the memory pressure turns out to be worse than the diagnosis benefit,
the decision should flip — see below.

## Revisit if

- Argo CD's footprint measurably forces a larger node class than workloads alone would need. That
  turns the trade above into a direct monthly cost, and Flux becomes the better answer.
- KSOPS proves fragile across Argo CD upgrades, since Flux's native SOPS support removes that
  failure mode entirely.
- The UI turns out to go unused in practice — if diagnosis happens through `kubectl` and logs
  anyway, the reason for choosing Argo CD over Flux has evaporated.
