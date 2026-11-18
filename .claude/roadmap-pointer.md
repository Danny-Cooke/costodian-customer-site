---
name: roadmap-pointer
description: Where the Costodian road map lives and which of its stages change this repository
metadata:
  type: reference
---

# Road map

The single road map for Costodian is in the sibling repository:
`../automation-portal/.claude/roadmap/costodian-roadmap.md` (written 18 November 2026).

Stages that change this repository:

- **Stage 1:** commit and push, the pipeline's first run, the split of the pipeline's
  permissions into one role per service, the redirect on the main website.
- **Stage 3:** the free sign-up backend (sign-in, API, storage); the pages keep their
  look and start saving.
- **Stage 7:** payment, and the account request raised when set-up is finished.
- **Stage 8:** every entry under "Stated on the site, not yet built" in `README.md` is
  built or removed, then the preview banner comes down.

The product was renamed from Draftsman to Costodian on 18 November 2026. The name is
`product.name` in `site/config/site.json`; the repository and AWS names still say
`draftsman`.
