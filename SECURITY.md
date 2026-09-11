# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability, please report it privately to the repository owner via GitHub's security vulnerability reporting feature (available on the repository's Security tab). Please do not open a public issue.

Provide as much detail as you can:

- A description of the vulnerability and its impact
- Steps to reproduce (if applicable)
- Affected version(s)
- Any proposed fix (optional)

## Scope

ripwire is a command-line indexing tool with the following security model:

- **Input:** Arbitrary source code repositories on the local filesystem
- **Output:** XML summaries and analysis results streamed to stdout or written to cache
- **Trust boundary:** The tool reads source with the user's own permissions. Network operations include cloning a git-URL root into the local cache (`git clone --depth=1`, with `protocol.ext.allow=never` and `protocol.file.allow=user` pinned on the command), listing the tree-sitter registry during initial setup, and connecting to an explicitly selected Redis analysis-cache backend
- **Subprocesses:** ripwire runs **read-only `git`** inside the analysed checkout (`status --porcelain`, `ls-files`, `log`, `diff --numstat`, `archive`, `rev-parse`), and — only for binary document formats, which are not collected by default — `markitdown`. Git honours the checkout's **own** `.git/config`. A *hook-form* `core.fsmonitor` there is a command git would run on every one of those calls, so ripwire neutralises that one key for its own git children at process start and says so (`--doctor`'s `git-config-trust` row; a stderr line carrying `git_harden=fsmonitor-hook`); boolean values, git's builtin daemon, are left alone. `git clone` never copies `.git/config`, so a repository you cloned yourself carries no such key — a tarball, a copied worktree or a shared checkout carries whatever its last owner wrote. Treat pointing ripwire at one as you would treat running `git status` there yourself

Security vulnerabilities relevant to this tool include:

- Memory safety issues (crashes, leaks, or corruption in the C++ implementation)
- Cache poisoning that could cause incorrect analysis results
- Path traversal or unintended file access
- Denial-of-service on valid inputs

## Shared Redis cache

Redis stores source-sensitive derived artifacts. Ingest records include relative paths, identifiers,
coordinates, metrics and lexical hashes; the document-extraction family contains full extracted
text. Git-derived families expose commit/date/path metadata and removed identifiers. The
[stored-data table](README.md#what-redis-stores) distinguishes each family's exact contents,
including which Git fields are not stored. Treat access to Redis as access to this data, even when
you do not cache full source files.

Key components use SHA-256 to separate namespaces, projects and content identities. Checksums and
hashes detect corruption and cross-identity substitution; they provide neither encryption nor
protection against an authorized writer fabricating analysis facts. Share a namespace/project only
with writers you trust. Binary encoding also leaves embedded paths, identifiers and document text
readable. Give the application a dedicated ACL restricted to `~rw:v1:*` and the command allowlist
in the [setup recipe](README.md#loopback-redis-through-ssh); use narrower per-scope ACLs when users
must be isolated. Redis databases and opaque namespace hashes are not authorization boundaries.

The client speaks plaintext RESP2 to a standalone Redis 6.2+ server. Use loopback or a local Unix
socket, with SSH forwarding for another computer. A remote socket requires
`RIPWIRE_REDIS_ALLOW_PLAINTEXT_REMOTE=1` and an already encrypted private overlay, a private-only
bind address and a restrictive firewall. This opt-in does not enable TLS: never use it over an
ordinary LAN or public Internet. URL credentials are forbidden; inject username/password through
the dedicated environment variables. Protect process environments and the server's ACL file.

Operators own server patching, authentication, firewall rules, access review, memory limits,
eviction policy and storage encryption. The default 30-day TTL slides on use; active keys may
remain indefinitely. Redis persistence, if enabled, writes this data to the server's disk and
requires an appropriate at-rest and retention policy. Disabling persistence makes a restart cold;
eviction or deletion loses cached work, not repository source. A bounded value size is not a server
memory budget. Prefer a dedicated instance with `maxmemory` and LRU/LFU eviction.

Selecting Redis does not move hook logs, session markers, notes, baselines or acknowledgement
sidecars off the client. Hook logging, opt-outs and retention remain as documented in
[the substitution meter](docs/SUBSTITUTION_METER.md#where-the-log-lives). Switching to File or
`--no-cache` does not purge Redis or existing local files. Follow the
[scoped cleanup procedure](README.md#switch-back-and-clean-up-deliberately), using a separate
administrator ACL for enumeration/deletion; do not delete an entire shared directory or database.

## No Version Promises

This project is pre-1.0 and does not yet provide a compatibility guarantee. Security fixes may be released as patch versions, minor versions, or major versions depending on the nature and severity of the issue. We will update this policy when the project reaches 1.0.

## Safe Practices

When using ripwire:

- Run it only on code you trust (or inspect before analyzing) — including its `.git/config` and hooks when the checkout did not come from your own `git clone`
- Use `--no-cache` or manage your cache directory if analyzing untrusted repositories in sequence
- Keep your source code checkout up to date to receive security fixes
