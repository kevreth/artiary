---
title: "PRD: Cypress Installation in a Containerized Session"
created: "2026-06-04"
status: "Skeleton — MUST BE EXPANDED"
---

# PRD: Cypress Installation in a Containerized Session

> **⚠️ SKELETON.** This is a stub capturing only what was observed in one
> session. It MUST be expanded — fuller context, generalization across
> container images, CI integration, and verification steps are all TODO.

## Problem

Running Cypress E2E tests inside a container (where `yarn test:all` /
`test:e2e` is the validation gate) failed out of the box for two reasons:

1. **Binary not installed** — `yarn cypress verify` reported
   `Cypress executable not found at .../<version>/Cypress/Cypress`. The
   npm package was present but the platform binary had not been downloaded.
2. **Missing execute permission** — after the binary downloaded, it
   extracted without an execute bit, so verification still failed with a
   permissions error.

No system Chrome was required — Cypress ships its own Electron browser, and
the container already had the shared libraries that Electron needs.

## What worked (observed, one session)

```bash
# 1. Download the platform binary into the Cypress cache
yarn cypress install

# 2. Make the cached binary executable (extraction dropped the exec bit)
chmod -R u+x ~/.cache/Cypress/<version>/Cypress/

# 3. Verify
yarn cypress verify        # → "Verified Cypress!"
```

After this, the full E2E suite booted the dev server and ran headless to
completion inside the container.

## Scope (to be defined)

- **In scope (TODO):** a repeatable, documented setup for Cypress in this
  project's container; where the cache path comes from; how to detect the
  missing-exec-bit condition; whether to bake it into the image vs. a setup
  script.
- **Out of scope (TODO):** confirm.

## Open questions (TODO)

- Is the missing exec bit a property of the image, the cache volume mount,
  or the download/extract step? Root-cause it.
- Should the binary be pre-baked into the container image, installed via a
  postinstall hook, or provisioned by a setup script?
- What exact shared libraries does the Electron browser rely on, and are
  they guaranteed present across the container images we use?
- How does this integrate with CI vs. local containerized dev?
- Pin the Cypress version and cache path rather than hardcoding.

## Success criteria (to be defined)

- [ ] `yarn cypress verify` passes from a clean container without manual steps
- [ ] `yarn test:e2e` runs headless to completion in the container
- [ ] The setup is documented and reproducible (not session-specific)
