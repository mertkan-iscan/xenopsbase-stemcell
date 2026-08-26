# ADR-0014: Provisioning the cluster and bootstrapping the platform are separate phases

- **Status:** Accepted
- **Date:** 2026-08-26
- **Task:** T-1.28 (#289)
- **Relates to:** [ADR-0004](0004-gitops-engine.md), [ADR-0013](0013-node-identity-is-injected.md)

## Context

ADR-0004 makes Argo CD the single owner of everything above the cluster. The bootstrap that installs
Argo CD itself runs inside the kube-hetzner module, as `user_kustomizations`, in three ordered stages
executed over SSH on a control-plane node during `terraform apply`. The comment on that block states
the intent plainly: *"Applied by the module during this same terraform apply, so the cluster goes
from nothing to reconciling in one step."*

That was correct while the module also created the agents, because they existed by the time stage 1
ran. T-1.23 moved agent creation into this repository, and terraform cannot create an agent until
the module returns. The bootstrap therefore now runs against a cluster with no worker.

Both T-1.23 builds failed there, and stage 2 is where it surfaces, because it is the only stage that
waits for something:

```
waiting for the Argo CD CRDs to appear (60/60)
Error from server (NotFound): customresourcedefinitions.apiextensions.k8s.io
  "applications.argoproj.io" not found
```

The wait is 60 x 5s and then a 120s `kubectl wait`. Seven minutes of an apply spent discovering that
a pod had nowhere to run.

ADR-0013 removes the ordering *constraint* — agents will no longer wait for the module. It does not
remove this problem, because the module still runs the bootstrap at the end of its own graph, and
whether an agent happens to be `Ready` by then is a race rather than a guarantee. A race that
usually wins is worse than one that always loses: it fails in staging, at a different node count,
months later.

## Decision criteria

1. **The bootstrap runs when nodes exist**, as a property of the graph, not of timing.
2. **One `make up`.** ADR-0002's near-zero-when-idle promise rests on rebuild being one command; a
   two-stage apply the operator must sequence by hand fails that.
3. **The seam is visible.** Someone reading the repository should be able to see where
   infrastructure ends and platform begins.
4. **Does not fork the module.**
5. **Failure names itself.** A bootstrap that cannot proceed should say which precondition is
   missing, not time out on a symptom.

## Decision

The module provisions machines and nothing above them. `user_kustomizations` is empty.

Installing Argo CD and applying the root Application become a terraform resource in this repository,
ordered explicitly after the nodes that will carry it. It runs in the same `terraform apply` — this
is a dependency edge, not a second phase the operator runs — and its precondition is stated rather
than waited for: at least one node `Ready` and schedulable for the workloads about to be created.

The seam is the sentence: **terraform creates machines and the secret that lets them find each
other; Argo CD creates everything else.** The Argo CD install is the last thing on the machine side
of that line, and it is the only part of the platform terraform ever touches.

## Consequences

### What this makes easy

The bootstrap can assume workers. Every platform chart stops needing to reason about whether it can
tolerate a control-plane taint on a cold build, which is a class of question that currently has no
consistent answer across the charts.

T-1.26 stops being blocked by it. Once the module bootstraps nothing, taking the control plane away
from it removes a machine rather than a mechanism.

`bootstrap: true` and per-chart tolerations both stop being tempting, because the situation they
were reaching for no longer occurs.

### What this makes hard

The kubeconfig problem ADR-0004 avoided comes back. The module runs kustomize over SSH on a node
precisely so nothing needs a kubeconfig that is an output of the same apply. Doing it here means
either the same SSH approach against a node we now own, or a provider configured from a value not
known at plan time — the two-stage-apply trap named in `manifests/10-argocd/helmchart.yaml.tpl`.
SSH-on-a-node is the closer analogue and keeps plan-time cleanliness, and is the expected shape.

CI cannot run this today. `docs/runbooks/cold-rebuild.md` already records that CI has no tailnet, so
anything reaching the cluster from the apply host is local-only. This decision does not make that
worse, but it does place one more thing on the wrong side of it.

### What it commits us to

Owning bootstrap ordering. The module currently encodes "Argo CD before the root Application, and
wait for the CRD" for us. That knowledge moves here, and it is the kind that is only discovered to
be wrong on a cold build.

Reversal is cheap and stays cheap: the stages are data, and handing them back to
`user_kustomizations` restores the current behaviour exactly.

## Alternatives considered

### Leave the bootstrap in the module and rely on ADR-0013's concurrency — rejected

It would probably work on dev most of the time. "Probably" and "most" are the objection: the failure
mode is a race whose outcome depends on how fast a node boots, and it would first be seen in an
environment that is not dev.

### Two applies, one for infrastructure and one for platform — rejected

It is the textbook separation and it breaks the one-command rebuild ADR-0002 depends on. A teardown
and rebuild that takes two commands is one people stop doing, and a cluster nobody destroys bills
all month.

### Move the Argo CD install into the golden image — rejected

Manifests in the image are static; the sops age key, the repo revision and the domain are not. It
would also put a platform decision inside an infrastructure artefact, which is the boundary this
ADR exists to draw.

## Revisit if

- CI gains tailnet access, at which point the local-only constraint stops shaping the choice.
- Argo CD is replaced by something with a different bootstrap story — ADR-0004 lists Flux, whose
  `flux bootstrap` is a single idempotent command and would make this seam narrower still.
- A second thing appears that terraform must install above the machine line. One is a seam; two is a
  platform layer, and that is a different decision.
