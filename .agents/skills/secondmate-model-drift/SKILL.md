---
name: secondmate-model-drift
description: >-
  Agent-only playbook for second mates running a model other than their recorded pin.
  Load after any Herdr restart, upgrade, or session resurrection while second mates are registered, and whenever a mate's live model is suspected to differ from its pin, for example a mate reporting itself on the harness default or the captain noticing a mate on the wrong model.
  Reconciles every local Claude Code mate's live model against its pin and relaunches drifted mates onto it.
user-invocable: false
metadata:
  internal: true
---

# Second mate model drift

A Herdr restart resurrects each Claude Code agent from its saved session but drops the launch flags, so a mate pinned to one model comes back on the harness default.
The mate's own `state/<id>.meta` still names the pinned model because nothing rewrote it, so that record never reveals the drift.
The mate cannot repair itself either when the pinned model is absent from Claude Code's interactive model picker.
`bin/fm-secondmate-model-reconcile.sh` detects the drift from live evidence and repairs it; its `--help` owns the flags, the signals it reads, the report vocabulary, the repair steps, and the exit codes.

## Procedure

1. Run `FM_HOME=<this home> bin/fm-secondmate-model-reconcile.sh --check` from the home whose mates you supervise.
2. Read one line per mate.
   `on-pin`, `skipped`, and `unpinned` need nothing; a pin whose model is `default` launches with no `--model`, so it reads `unpinned`.
   `unknown` means no live signal was readable, so inspect that mate's endpoint by hand before acting; never repair on no evidence.
   `drifted` names which signal disagreed with the pin.
3. When any mate is `drifted`, run the same command with `--apply`, restricted to those ids when others are mid-task.
   A `repaired` line proves the relaunched session is live on the pin.
   A `drifted ... not repaired:` line names why it stood down - another actor's lease, an open liveness episode, a mid-turn agent, or a composer not proven empty - so rerun after that clears.
   Pending composer text (an unsubmitted steer, a doorbell, or the captain's draft) is never cleared; the repair refuses instead, so submit or clear that text deliberately before rerunning.
   A `failed` line names the step that refused; the mate is either still running unchanged or exited and left to the liveness sweep, which relaunches on the pin.
4. Rerun `--check` until every mate reads `on-pin`, then reconcile each repaired mate's open work the way any secondmate relaunch is reconciled under `secondmate-provisioning`.

## Boundaries

- The pin is the only source of truth; never edit `config/secondmate-harness.<id>` to match a drifted session, and never change the fleet model as part of a repair.
- `--apply` takes the mate's task lease and liveness lock for the whole repair and releases only what it took, so do not claim or clear either by hand around it.
- The liveness sweep may still report a `check: secondmate <id> auto-relaunched` or `auto-relaunch failed` wake for a mate this command touched; that is a reconciliation signal, never a reason to relaunch again or to disable the sweep, because the spawn lock prevents a duplicate endpoint.
- Remote mates are skipped because their live process is not readable from this host; reconcile them from their own host.
- Only Claude Code pins are checked, because both live readings are verified for Claude Code alone.

## Upstream root cause

The durable fixes are outside this command and remain follow-up work: Herdr resurrecting an agent with its original argv, and `bin/fm-secondmate-restart.sh` proving the pin survived its own relaunch.
Until both land, run this check after every Herdr restart or upgrade.
