# Contributing

This is a written series about running vLLM on Kubernetes in production. Corrections and updates are
welcome, especially since vLLM and the surrounding ecosystem move quickly.

## What good changes look like

- Keep the production focus. The series is for people who already know Kubernetes and want the
  decisions, trade-offs, and failure modes, not a hello-world.
- Keep the three tip tiers where they fit: Senior Dev tip, Senior DevOps tip, Architect tip.
- YAML in the chapters is illustrative and production-shaped. It is meant to be read and adapted, not
  applied blind, so prefer clarity over completeness in the snippets.
- If a flag, API, or version note has gone stale, say what it is now and roughly when that changed.

## Before you push

```bash
make links        # internal markdown links resolve
make shellcheck   # if you touched serve.sh
```

CI runs the same checks.
