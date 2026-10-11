# deploy/

A personal deployment setup for this fork — a build script that publishes a
versioned image + GitHub Release, and a Docker Compose stack to run it.
Separate from the rest of the repo on purpose (its own subfolder, touches
nothing upstream owns) so pulling future changes from upstream never
conflicts with it.

Nothing here is required to use ARTEX itself — see the root `README.md` for
the general install paths (`install.sh`, the Docker Compose quick start, or
a manual single-binary build). This is specifically how *this* deployment
builds and runs it.

## What was verified before this existed, and what wasn't

Before any of this was written, the fork was reviewed end-to-end: every
package, the one closed-source dependency it still pulls (by content hash,
not trust), and the GitHub Actions workflows. No backdoor or tampering
found — if anything, the defensive engineering in it (SSRF guards on the
notification channels, credential-leak prevention when a webhook/telegram/
email destination changes, an explicit catastrophic-command denylist on the
Bash tool) is unusually good for a days-old community fork of a tool whose
original upstream was linked to real bank intrusions and then taken down.

That review was followed by **one full smoke test** against OWASP Juice
Shop, in a Docker lab fully network-isolated from everything else on the
deploying machine (verified both directions — nothing in, nothing out
except the target and the LLM API). It found 14 correct findings — SQLi
auth bypass, JWT `alg:none` forgery, mass-assignment privilege escalation,
IDOR, DOM XSS, and more — matching Juice Shop's actual vulnerability set
almost one-for-one.

That's one clean run against a toy app, not a production bake-in. Treat it
accordingly: this deploys to a development/sandbox host, not a production
one, and **network isolation at the deploy host's own firewall was a
deliberate, explicit decision to defer, not an oversight** — this setup
relies on an existing reverse-proxy + per-host firewall model instead of
adding new isolation for this specifically. Revisit before pointing it at
anything beyond a local/isolated target.

## Layout

```
deploy/
├── publish.sh            # build + push + release — run on a build host, never a prod/sandbox one
├── stack.yml             # the actual deployment (Compose)
├── stack.env.example     # tracked template — names only, no real values
└── stack.env             # real secrets — gitignored, never commit
```

## Build + publish

```bash
cd deploy
./publish.sh v0.1.0
```

Builds `linux/amd64` only (this is a Docker deployment, not a native-binary
distribution). Pushes `ghcr.io/braedach/artex:<tag>` and `:latest`, and
creates a matching GitHub Release (zip + `SHA256SUMS`) on this repo. (Fork
this further yourself? Change `GHCR_NAMESPACE`/`GH_REPO_SLUG` near the top
of `publish.sh` to your own.)

**Needs:**
- `git`, `docker`, and the `gh` CLI on whatever host runs it
- a **classic** GitHub PAT — `write:packages` + `repo` scope (GHCR push does
  not work reliably with a fine-grained PAT, regardless of the scopes it's
  granted)
- run it on a build host, not wherever ARTEX itself ends up running, and
  from a clone dedicated to publishing — it checks out the requested tag
  in-place, which would otherwise yank you off whatever branch you're
  developing on

The script prompts for the token interactively the first time, or reads a
cached copy from `build/.ghcr-token` (chmod 600, gitignored) for
unattended/repeat runs — never pass it as a CLI argument or env var at the
shell (history/`ps` exposure), and never commit it.

**One-time, after the first push:** GHCR defaults a new package to private.
Flip `ghcr.io/<your-namespace>/artex` to Public in GitHub's package
settings, and make sure the repo itself is public too, or Compose on the
deploy host won't be able to pull it without its own credentials.

## Deploy

```bash
cd deploy
cp stack.env.example stack.env   # fill in real values, never commit this
docker compose -f stack.yml --env-file stack.env up -d
```

`stack.yml` only ever pulls the image `publish.sh` built — it never builds
anything itself. It declares its own `artex-net` network (nothing else
should be attached to it) and a Postgres sidecar on a bind-mounted volume
(`./volume/postgres`, not a named Docker volume, so it's visible/backupable
as plain files). Front it with whatever reverse proxy you already use —
`stack.yml`'s `homepage.*` labels assume a label-driven dashboard
([gethomepage.dev](https://gethomepage.dev) or similar); drop them if you
don't use one.

`ARTEX_LANG=en` is defaulted in `stack.yml` itself, so the UI and
agent-generated output (findings, reports, chat replies) start in English
even if `stack.env` doesn't set it explicitly — confirmed against this
fork's actual startup precedence (`server/server.go`: a runtime setting
chosen in Settings overrides `ARTEX_LANG`, which overrides this default).
Once someone changes the language from the Settings UI, that choice is
stored in Postgres and wins from then on regardless of this default.

## What to keep in mind

- No `cap_drop`/`read_only` hardening is applied in `stack.yml` yet —
  ARTEX's own tooling (`nmap` in particular) likely needs `NET_RAW`/
  `NET_ADMIN`, and Playwright/Chromium tends to want a writable
  filesystem. Worth tightening once it's actually running, not assumed
  blind.
- `stack.yml` is Docker-specific (plain Compose). Porting this to a
  Podman host isn't a copy-paste — Podman's networking/firewall
  interaction differs enough that it needs its own pass, not attempted
  here.
- Never commit `stack.env`, the GHCR token, or any API key anywhere in
  this repo. `*.env` is gitignored; keep it that way.
