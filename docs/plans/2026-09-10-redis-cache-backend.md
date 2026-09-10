# Redis Cache Backend Implementation Plan

> **Execution skill:** Use `Skill(subagent-driven-development)` (recommended) or inline execution. Steps use `- [ ]` checkbox syntax.

**Goal:** Add an opt-in Redis cache backend that lets compatible computers reuse ripwire's parsed index and immutable derived caches without creating persistent local cache blobs, while keeping the current filesystem backend as the byte-identical default.

**Architecture:** Resolve one immutable cache policy at the CLI/library boundary and derive a context for each root. The filesystem branch continues to call the existing blob codecs and atomic file writers. The Redis branch uses a dependency-free RESP2 client and stores ingest data as immutable content-addressed per-file records plus independently expiring per-path descriptors, then stores other immutable caches through a binary blob API. Cache data remains disposable: every hit is versioned and validated, and every Redis error degrades to an uncached computation without changing stdout.

**Tech Stack:** C++23, POSIX TCP/Unix sockets, RESP2, existing ripwire binary codecs and FNV/checksum guards, Bash regression gates, Python deterministic RESP fixture, GitHub Actions Redis service.

---

## Product and security contract

These are deliberate scope decisions for the first Redis backend, not placeholders:

- The backend is activated by `--cache=redis` or `RIPWIRE_CACHE_BACKEND=redis`. Existing `--cache=PATH`, default caching, and `--no-cache` retain their current behavior.
- Redis activation requires `RIPWIRE_REDIS_URL` and `RIPWIRE_REDIS_NAMESPACE`; there is no implicit network endpoint. Username/password are optional only when the selected Redis policy intentionally allows unauthenticated access.
- Connection policy uses `RIPWIRE_REDIS_USERNAME`, `RIPWIRE_REDIS_PASSWORD`, optional `RIPWIRE_REDIS_PROJECT`, `RIPWIRE_REDIS_TTL_DAYS` (default 30), `RIPWIRE_REDIS_TIMEOUT_MS` (default 1000), and the explicit `RIPWIRE_REDIS_ALLOW_PLAINTEXT_REMOTE=1` escape hatch.
- Precedence is `--no-cache` > explicit `--cache=PATH|redis` > `RIPWIRE_CACHE_BACKEND=redis` > default local filesystem cache. A literal file named `redis` remains addressable as `--cache=./redis`.
- Redis contains disposable derived data: relative file paths, content/stat metadata, parse-health counters, symbols/signatures/docs, references, includes, bindings, routes, constant-open facts, lexical postings, and serialized quality/oracle/merge/doc-extraction results. It does not receive edit locks, sidecar locks, materialized Git trees, cached remote clones, `.ripwire_notes`, `.ripwire_quality_baseline`, or `.ripwire_quality_acks`.
- Redis saves disk on each client computer, not necessarily on the Redis host. Redis persistence, eviction, backups, and encryption at rest remain operator responsibilities.
- The default TTL is 30 days. Successful reads refresh active descriptors and referenced values. Immutable orphan records and stale per-path descriptors expire independently.
- A Redis outage, authentication failure, malformed reply, missing value, or corrupt value emits one redacted `DEGRADED_PATH_ALERT` warning per process and runs uncached. It never silently falls back to a persistent local cache because that would violate the user's disk-space choice.
- The normal multi-computer topology is a loopback Redis reached through SSH or a private overlay tunnel. Plaintext TCP to a non-loopback address is refused unless `RIPWIRE_REDIS_ALLOW_PLAINTEXT_REMOTE=1`. `rediss://`, Redis Cluster redirects (`MOVED`/`ASK`), Sentinel discovery, and client-side TLS are rejected with actionable diagnostics in this iteration.
- Credentials are accepted only through `RIPWIRE_REDIS_USERNAME` and `RIPWIRE_REDIS_PASSWORD`; URL userinfo and CLI credential flags are rejected. Credentials never enter cache keys, stdout, stderr, XML, profiles, or `--doctor` output.
- Shared identity is `RIPWIRE_REDIS_NAMESPACE` plus a project ID. The project ID defaults to a normalized credential-free Git remote plus the repo-relative crawl root; `RIPWIRE_REDIS_PROJECT` is required for non-Git roots and is the explicit override for computers whose remotes differ. Redis key components use fixed-width hashes; this avoids readable path names in key listings but is not presented as encryption.
- Redis and every client with write access are inside ripwire's trusted cache boundary: a writer can replace derived analysis data. Namespace strings, logical DB numbers, and hashed keys are collision controls, not authorization. Operators must use a dedicated Redis ACL user restricted to ripwire's key prefix and command set, and must not share that ACL with less-trusted writers.

## Key and consistency model

Use keys shaped as follows, where every brace-delimited identity component is a fixed-width lowercase hex hash:

```text
rw:v1:{namespace}:{project}:ingest:{cacheVersion}:{parserVersion}:{arch}:{lean|rich}:descriptor:{pathHash}
rw:v1:{namespace}:{project}:ingest:{cacheVersion}:{parserVersion}:{arch}:{lean|rich}:record:{pathHash}:{sourceDigest}
rw:v1:{namespace}:{project}:blob:{family}:{schemeVersion}:{arch}:{identityHash}
```

Each path descriptor is an independent expiring string value containing a SHA-256 source digest, SHA-256 record digest, legacy record checksum, and record length. Readers always digest current source bytes and address `record:{pathHash}:{sourceDigest}` directly; the descriptor is a liveness/discovery hint, never the authority for current content. Writers publish immutable records with `SET ... NX EX ttl`, verify an already-present value before reusing it, and only then publish the per-path descriptor with `SET ... EX ttl`. A narrower/excluded crawl touches only paths it saw. Descriptors for deleted or long-excluded paths expire independently even while the project stays hot. An absent/corrupt record reparses only that file. Concurrent writers commute for different paths; if writers race on the same path, either descriptor may win without hiding the content-addressed record needed by a reader. A crash can leave a dangling record or omit a descriptor, both harmless and TTL-bounded. The existing record checksum and decoder remain defense in depth. SHA-256 protects against accidental/collision poisoning; the ACL trust boundary protects against malicious writers.

## Task 1: Lock the backend configuration and identity contract

**Files:**

- Create `src/cache_backend.h`
- Create `src/cache_backend.cpp`
- Create `test/rediscacheconfigcheck.sh`
- Modify `src/cli.h`
- Modify `src/main.cpp`
- Modify `CMakeLists.txt`
- Modify `test/regression.sh`

**Done when:** CLI and environment inputs resolve to one immutable `CachePolicy`, each known root derives a `CacheContext`, project identity is stable across absolute checkout paths, filesystem/no-cache behavior is unchanged, and invalid Redis settings fail before ingest with redacted messages.

**Out of scope:** Opening a Redis connection or changing any cache read/write path.

- [ ] Add `test/rediscacheconfigcheck.sh` first. Its isolated fixture must assert:
  - default execution still creates/uses the existing local cache;
  - `--no-cache` wins over both Redis activation mechanisms;
  - explicit `--cache=PATH` wins over `RIPWIRE_CACHE_BACKEND=redis`;
  - `--cache=redis` and the environment activation resolve Redis;
  - `--cache=./redis` resolves a file;
  - Redis requires an endpoint, namespace, and either a normalizable Git remote or project override;
  - two copies of the same Git repository at different absolute paths produce the same project identity;
  - known SHA-256 vectors produce the expected full 64-hex key hash;
  - URL userinfo (including percent-encoded forms), `rediss://`, remote plaintext without opt-in, invalid DB/TTL/timeout, unknown query parameters, controls/NULs, fragments, ambiguous escapes, and unknown backend values are rejected;
  - a password-shaped sentinel is absent from stdout and stderr.
- [ ] Register `rediscacheconfigcheck` in the explicit gate list in `test/regression.sh` before implementation.
- [ ] Run `cmake -S . -B build && cmake --build build -j && RIPWIRE_BIN=./build/ripwire bash test/rediscacheconfigcheck.sh`. Expected result: the new gate fails because Redis is not a recognized cache target.
- [ ] Add the value types and pure resolvers in `src/cache_backend.h`:

```cpp
namespace rw
{
enum class CacheBackendKind : std::uint8_t { Disabled, File, Redis };

struct RedisCacheConfig
{
    std::string endpoint;
    std::string username;
    std::string password;
    std::string nameSpace;
    std::string project;
    std::uint32_t ttlSeconds = 30u * 24u * 60u * 60u;
    std::uint32_t timeoutMs = 1000;
    bool allowPlaintextRemote = false;
};

struct CachePolicy
{
    CacheBackendKind kind = CacheBackendKind::Disabled;
    std::string explicitFilePath;
    RedisCacheConfig redis;
};

struct CacheContext
{
    std::shared_ptr<const CachePolicy> policy;
    std::string filePath;
    std::string project;
    bool captureValueUses = true;
};

struct CacheSelectionInput
{
    bool noCache = false;
    bool cacheWasExplicit = false;
    std::string_view explicitCache;
    std::string_view environmentBackend;
};

bool resolveCachePolicy( const CacheSelectionInput& input, std::shared_ptr<const CachePolicy>& out, std::string& error );
bool cacheContextForRoot( std::shared_ptr<const CachePolicy> policy, std::string_view root,
                          bool captureValueUses, CacheContext& out, std::string& error );
std::string redisProjectIdentity( std::string_view root, std::string_view overrideValue, std::string& error );
std::string redisKeyHash( std::string_view value );
}
```

- [ ] Keep secrets in owned strings so environment storage lifetime cannot leak through `string_view`. Implement a structured, non-shell Git-remote parser. Normalize supported `https://host/owner/repo.git`, `ssh://git@host/owner/repo.git`, and `git@host:owner/repo.git` forms to the same credential-free identity; lowercase only scheme/host, preserve meaningful non-default ports and case-sensitive paths, and include the repo-relative crawl root rather than the absolute checkout root. Reject controls, NULs, fragments, query strings, encoded userinfo, ambiguous percent encodings, and unsupported transports without printing the input.
- [ ] Implement `redisKeyHash` as dependency-free SHA-256 returning all 64 lowercase hex digits. Use it for namespace, project, blob identities, source bytes, and record bytes; retain existing FNV/checksum fields only for wire compatibility and fast internal lookup. Test standard vectors and binary input.
- [ ] Add only the Redis activation variables to CLI parsing/help. Do not add username/password flags. Count new flags in `kTotalFlagArms` and extend the existing CLI count/assertion gates.
- [ ] Resolve `CachePolicy` once in `dispatchMain`, then derive a `CacheContext` after each root is known. For multi-root and MCP input, derive a separate project ID per root while sharing the immutable endpoint/credentials/namespace/TTL policy.
- [ ] Run `RIPWIRE_BIN=./build/ripwire bash test/rediscacheconfigcheck.sh`. Expected result: pass.
- [ ] Commit the contract slice:

```bash
git add src/cache_backend.h src/cache_backend.cpp src/cli.h src/main.cpp CMakeLists.txt test/rediscacheconfigcheck.sh test/regression.sh
git commit -m "test(cache): lock Redis configuration contract"
```

## Task 2: Implement a bounded dependency-free RESP2 client

**Files:**

- Create `src/redis_client.h`
- Create `src/redis_client.cpp`
- Create `test/redis_protocol_unit.cpp`
- Create `test/redis_stub.py`
- Create `test/redisclientcheck.sh`
- Modify `CMakeLists.txt`
- Modify `test/regression.sh`

**Done when:** ripwire can authenticate, select a DB, send binary-safe commands/pipelines, and parse bounded RESP2 replies over TCP or Unix sockets with deterministic failure classification.

**Out of scope:** TLS, Pub/Sub, Lua, transactions, Sentinel, Redis Cluster, RESP3, connection pooling, and a background network thread.

- [ ] Write `test/redis_protocol_unit.cpp` before implementation. Cover simple strings, errors, signed integers, nil bulk strings, empty/binary bulk strings containing NUL, arrays, split/truncated frames, invalid prefixes, negative non-nil lengths, decimal overflow before allocation, oversized bulk lengths, oversized array counts, excessive nesting, trailing garbage, outbound request/pipeline ceilings, and `MOVED`/`ASK` classification.
- [ ] Write `test/redis_stub.py` as a concurrent deterministic local fixture. It must support `AUTH`, `SELECT`, `PING`, `GET`, `MGET`, `SET ... NX EX`, `EXPIRE`, `TTL`, `TYPE`, `SCAN`, `DEL`, and `UNLINK`; record commands as length-delimited data; and expose a separate loopback-only test-admin socket with `advance_clock(seconds)`, `delete(key)`, `replace(key, bytes)`, `fail_before(command_index)`, `fail_after(command_index)`, `hold(barrier)`, `release(barrier)`, and `command_log()`. Fault modes must include truncation, malformed/slow-drip frames, a server that does not read, delay/absolute-deadline expiry, dropped connections, auth errors, missing records, and corrupt payloads.
- [ ] Add `test/redisclientcheck.sh` to exercise TCP; hostname-only-remote and mixed loopback/remote resolution refusal; post-connect peer validation; Unix socket authentication; symlink/regular-file/unsafe-owner-or-mode/path-swap refusal; DB selection; next-operation recovery after a dropped connection; absolute read/write timeout; binary payloads; pipelining order; and secret/path redaction. Register it in `test/regression.sh`.
- [ ] Add `ripwire_test_redis_protocol` under the existing `RIPWIRE_TESTS` branch and register `add_test(NAME ripwire.redis_protocol COMMAND ripwire_test_redis_protocol)`. Run `cmake -S . -B build_tests -DRIPWIRE_TESTS=ON && cmake --build build_tests -j`. Expected result: compilation fails because the new client API is missing.
- [ ] Implement the following bounded interface:

```cpp
namespace rw
{
enum class RedisReplyType : std::uint8_t { Simple, Error, Integer, Bulk, Nil, Array };
enum class RedisFailure : std::uint8_t { None, Config, Connect, Timeout, Protocol, Auth, ClusterRedirect, Server };

struct RedisReply
{
    RedisReplyType type = RedisReplyType::Nil;
    std::string bytes;
    std::int64_t integer = 0;
    std::vector<RedisReply> elements;
};

struct RedisResult
{
    RedisFailure failure = RedisFailure::None;
    RedisReply reply;
    std::string diagnostic;
    explicit operator bool() const noexcept { return failure == RedisFailure::None; }
};

class RedisClient
{
public:
    explicit RedisClient( const RedisCacheConfig& config );
    RedisResult command( const std::vector<std::string_view>& parts ) const;
    std::vector<RedisResult> pipeline( const std::vector<std::vector<std::string>>& commands ) const;
};
}
```

- [ ] Encode every command as a RESP array of bulk strings; never interpolate shell or protocol text. Parse only `redis://HOST[:PORT][/DB]` and `redis+unix:///absolute/path?db=DB` with a strict grammar: reject userinfo, fragments, unknown query keys, controls/NULs, ambiguous percent encodings, invalid IPv6 brackets, and extra path components before resolution or diagnostics.
- [ ] For TCP, use `getaddrinfo`, nonblocking `connect` plus `poll`, `send`, and `recv`. Without plaintext-remote opt-in, classify every resolved `sockaddr` and connect only to `127.0.0.0/8`, `::1`, or IPv4-mapped loopback; reject wildcard, link-local, private, public, and mixed remote results, then verify the connected peer again with `getpeername`. The opt-in disables this ripwire transport protection and does not add encryption.
- [ ] For Unix sockets, `lstat` the final path, reject symlinks/non-sockets, require the endpoint and traversed parents to be owned by the effective user or root with safe write/sticky-bit rules, record device/inode before connection and recheck after, and verify the peer UID with `SO_PEERCRED`/`getpeereid` where supported. Never fall back from Unix to TCP. Treat the configured socket location as a credential trust boundary.
- [ ] Set close-on-exec on every socket, handle `EINTR` and partial I/O, and suppress `SIGPIPE` with the platform's per-send/per-socket mechanism. Use one monotonic absolute deadline for the complete connect/AUTH/SELECT/request/reply operation; progress must not reset it.
- [ ] Set parser and encoder ceilings in code and tests: 64 MiB per bulk value, 4,096 elements per array, 16,384 decoded nodes, depth 4, 128 MiB aggregate reply bytes, 256 commands per pipeline batch, and 8 MiB encoded request bytes per batch. Count framing/nested-container bytes, check decimal/addition/multiplication overflow before allocation, and chunk repository-sized descriptor lookups, record reads/writes, and TTL refreshes. Treat every ceiling violation as a protocol failure and close the socket.
- [ ] Make each public operation own its socket. On connection: optional `AUTH username password` (or `AUTH password` when username is empty), optional `SELECT`, then the requested command(s). This keeps CLI and MCP prefetch call sites thread-safe without a pool or shared descriptor.
- [ ] Ensure diagnostics name only endpoint class (`loopback TCP` or `Unix socket`), failure class, and Redis error category. Never include full URLs, commands, usernames, passwords, payloads, or server replies that may echo secrets.
- [ ] Run `ctest --test-dir build_tests --output-on-failure -R '^ripwire\.redis_protocol$' && RIPWIRE_BIN=./build/ripwire bash test/redisclientcheck.sh`. Expected result: pass.
- [ ] Commit the transport slice:

```bash
git add src/redis_client.h src/redis_client.cpp test/redis_protocol_unit.cpp test/redis_stub.py test/redisclientcheck.sh CMakeLists.txt test/regression.sh
git commit -m "feat(cache): add dependency-free Redis transport"
```

## Task 3: Factor reusable per-file ingest record codecs

**Files:**

- Modify `src/ingest_cache.h`
- Create `test/cacherecordcheck.sh`
- Modify `test/regression.sh`

**Done when:** one file's existing record bytes can be encoded and decoded independently, while the filesystem cache remains byte-for-byte compatible at the current cache version 18.

**Out of scope:** Redis calls or a cache-version bump.

- [ ] Add `test/cacherecordcheck.sh` first. Build a corpus containing every serialized fact family and commit architecture-specific golden rich/lean v18 cache fixtures (or fixed byte-size and SHA-256 expectations) produced by the unmodified encoder, with an explicit regeneration command and source commit. The post-refactor gate compares new output to that independent baseline. Add a test-only round trip for one extracted record, including embedded NULs and maximum accepted counts. Register the gate.
- [ ] Run `RIPWIRE_BIN=./build/ripwire bash test/cacherecordcheck.sh`. Expected result: the fixture cannot call independent record helpers.
- [ ] Extract the body of the current per-file loop in `saveCache` into:

```cpp
struct EncodedCacheRecord
{
    std::string bytes;
    std::uint64_t pathHash = 0;
    std::uint64_t contentHash = 0;
    std::uint32_t sum = 0;
};

struct CacheEncodeInput
{
    const std::vector<std::uint64_t>& fileHash;
    const std::vector<long long>& fileSize;
    const std::vector<long long>& fileMtime;
    const std::vector<long long>& fileCtime;
    const std::vector<FileHealth>& fileHealth;
    const std::vector<RawDef>& defs;
    const std::vector<RawRef>& refs;
    const std::vector<Include>& incs;
    const std::vector<RawBind>& binds;
    const std::vector<BindingAlias>& ffis;
    const std::vector<RouteDef>& routeDefs;
    const std::vector<RawRouteUse>& routeUses;
    const std::vector<ConstOpen>& constOpens;
    bool captureValueUses = true;
};

struct CacheRecordExpectation
{
    std::string_view relativePath;
    std::uint64_t pathHash = 0;
    std::uint64_t contentHash = 0;
    bool captureValueUses = true;
};

struct CacheDecodeOutput
{
    std::vector<RawDef>& defs;
    std::vector<RawRef>& refs;
    std::vector<Include>& incs;
    std::vector<RawBind>& binds;
    std::vector<BindingAlias>& ffis;
    std::vector<RouteDef>& routeDefs;
    std::vector<RawRouteUse>& routeUses;
    std::vector<ConstOpen>& constOpens;
    FileHealth& health;
};

EncodedCacheRecord encodeCacheRecord( std::uint32_t fileId, const CachePathKeys& keys,
                                      const CacheFileIndexes& indexes, const CacheEncodeInput& input );

bool decodeCacheRecord( std::string_view record, const CacheRecordExpectation& expected,
                        CacheDecodeOutput& output );
```

- [ ] Make `saveCache` append `EncodedCacheRecord::bytes` and construct the unchanged offset table. Make `loadCache` call `decodeCacheRecord` after its existing frame/table checks. Preserve relative-path, content-hash, stat-gate, parse-health, lexical dictionary, checksum, count, and bounds validation exactly once inside the shared decoder.
- [ ] Keep carry-forward records byte-verbatim. Derive all guards through `cacheIdentity()`, `kCacheVersion`, `parserVerFor()`, and `kArtifactArch`; do not duplicate numeric versions in implementation. Do not reinterpret older records or change header bytes, record ordering, or trailer bytes.
- [ ] Run `RIPWIRE_BIN=./build/ripwire bash test/cacherecordcheck.sh && RIPWIRE_BIN=./build/ripwire bash test/savecachecheck.sh && RIPWIRE_BIN=./build/ripwire bash test/portablecachecheck.sh`. Expected result: all pass and cache hashes match the pre-refactor fixture.
- [ ] Commit the codec refactor:

```bash
git add src/ingest_cache.h test/cacherecordcheck.sh test/regression.sh
git commit -m "refactor(cache): expose validated file records"
```

## Task 4: Store ingest records and path descriptors in Redis

**Files:**

- Create `src/ingest_cache_redis.h`
- Modify `src/ingest.h`
- Modify `src/ingest.cpp`
- Modify `src/ingest_parsepool.h`
- Modify `src/main.cpp`
- Create `test/redisingestcheck.sh`
- Modify `test/regression.sh`

**Done when:** two absolute checkouts with the same shared identity reuse per-file parse records; edits/corruption reparse only affected files; Redis mode creates no persistent local `ripwire-*.bin`.

**Out of scope:** Quality/oracle/merge/doc-derived caches.

- [ ] Add `test/redisingestcheck.sh` first using `test/redis_stub.py`. Assert:
  - checkout A cold run reports every file reparsed;
  - checkout B is an independent Git repository with equivalent HTTPS/SSH/SCP remote spelling, different absolute path/inodes/mtimes, and identical source bytes; it reports `reparsed=0` through `RIPWIRE_CACHE_STATS=1` and produces identical stdout;
  - different repo-relative crawl roots and different project overrides do not cross-hit;
  - with private `TMPDIR` and `XDG_CACHE_HOME`, a before/after inventory of every regular file in the complete cache ladder shows no new persistent artifact; the only allowed local objects are explicitly named locks/temp artifacts required by the command;
  - changing one file reparses exactly one file and warm output equals `--no-cache`;
  - deletion and a narrower exclude set do not delete unrelated descriptors or alter output; after clock advancement, deleted/long-excluded descriptors expire while actively reused paths remain live;
  - lean/rich, parser/cache version, architecture, namespace, and project IDs are isolated;
  - projects in the same namespace cannot cross-poison;
  - a missing/corrupt record reparses only its path;
  - two concurrent writers over overlapping subsets leave every published content-addressed record usable regardless of descriptor last-writer order;
  - auth/outage/timeout runs are uncached, produce byte-identical stdout, warn once, and do not create a local cache.
- [ ] Run `RIPWIRE_BIN=./build/ripwire bash test/redisingestcheck.sh`. Expected result: fail because ingest ignores `CacheContext::Redis`.
- [ ] Preserve the public filesystem signature in `src/ingest.h` and add a backend-aware overload:

```cpp
IngestResult ingest( const char* rootDir, const std::vector<std::string>& excludeSubstr,
                     const CacheContext& cache, std::size_t maxFileBytes = kDefaultMaxFileBytes,
                     bool captureValueUses = true, std::string_view excludeLabel = {},
                     bool respectGitignore = true );

IngestResult ingest( const char* rootDir, const std::vector<std::string>& excludeSubstr = {},
                     std::string_view cacheFile = {}, std::size_t maxFileBytes = kDefaultMaxFileBytes,
                     bool captureValueUses = true, std::string_view excludeLabel = {},
                     bool respectGitignore = true );
```

- [ ] In `src/ingest_cache_redis.h`, build descriptor/record prefixes from namespace/project plus `cacheIdentity()`, `parserVerFor(captureValueUses)`, `kArtifactArch`, and lean/rich. SHA-256 every current source file and directly request `record:{pathHash}:{sourceDigest}` through byte/item-bounded `MGET` batches; do not trust a cross-machine stat tuple or mutable descriptor to choose content. Fetch per-path descriptor values only for validation/liveness telemetry. Verify the record SHA-256, legacy checksum, bounds, expected relative path, and source digest before `decodeCacheRecord`. Nil, invalid descriptor, oversize, checksum/digest error, or decoder refusal is a miss only for affected paths/batches.
- [ ] On save, serialize only crawled file records. Process bounded batches and issue `SET recordKey envelope NX EX ttl`; if Redis reports the key already exists, `GET` and verify its digest before treating publication as successful. For each successful record, publish `SET descriptorKey descriptor EX ttl`. Fault-inject before/after both commands and assert every created key is absent or has `TTL > 0`, never `TTL == -1`. Never publish a descriptor whose record write or existing-record verification failed.
- [ ] On a successful hit, pipeline bounded `EXPIRE` batches for its record and descriptor keys. TTL refresh failure must not invalidate a verified hit, but it must use the same once-per-process degraded warning budget.
- [ ] Add one process-wide atomic Redis-warning latch. On the first backend failure, the debug branch emits `DEGRADED_PATH_ALERT` and the release branch emits the equivalent redacted `fprintf` line, so either build produces one line rather than both; later failure classes stay silent in normal execution but remain queryable by doctor. Test timeout, malformed reply, and auth/server failure sequentially in one MCP process and assert exactly one warning. Do not call `VERIFY(false)` on any Redis degradation path.
- [ ] Dispatch in `src/ingest.cpp`: disabled skips load/save; file calls existing `loadCache`/`saveCache`; Redis calls the new descriptor/record helpers. Pass `const CacheContext&` into `runParsePool` in `src/ingest_parsepool.h`, derive `needsCacheHash` from backend kind, and dispatch dirty saves there. Preserve the `runDocPostPass` cache-enabled signal for Task 6's blob routing. No branch may influence result ordering or map serialization.
- [ ] Run the new gate, then run each existing gate explicitly: `RIPWIRE_BIN=./build/ripwire bash test/redisingestcheck.sh`, `test/cacheidentitycheck.sh`, `test/cacheisolationcheck.sh`, `test/cacheoffsetcheck.sh`, `test/cachesplitcheck.sh`, `test/portablecachecheck.sh`, `test/savecachecheck.sh`, `test/racymtimecheck.sh`, `test/statgatecheck.sh`, and `test/tornreadcheck.sh`. Expected result: pass.
- [ ] Commit the ingest slice:

```bash
git add src/ingest_cache_redis.h src/ingest.h src/ingest.cpp src/ingest_parsepool.h src/main.cpp test/redisingestcheck.sh test/regression.sh
git commit -m "feat(cache): share ingest records through Redis"
```

## Task 5: Route MCP foreground ingest through the same backend

**Files:**

- Modify `src/mcpindex.h`
- Modify `src/mcp.h`
- Modify `src/mcpserver.h`
- Modify `src/main.cpp`
- Create `test/redismcpcheck.sh`
- Modify `test/regression.sh`

**Done when:** MCP foreground index builds derive a per-request/root `CacheContext`, reuse Redis safely, and create no local persistent cache blobs; Redis-mode quality prefetch is explicitly suppressed until Task 6 routes its two cache layers.

**Out of scope:** Background quality-snapshot prefetch (completed in Task 6), mutable MCP session state, open file handles, watcher queues, or request/response data.

- [ ] Add `test/redismcpcheck.sh` first. Start the fixture, run two MCP processes against independent copies of one repo with private `TMPDIR`/`XDG_CACHE_HOME`, enable `RIPWIRE_CACHE_STATS=1`, and assert the second process's initial foreground index reports `reparsed=0`, emits valid framing, performs no replacement `SET`, and creates no unallowlisted persistent local file. Force a dropped connection during foreground rebuild and assert the server remains responsive and the failure is redacted. Assert Redis mode does not start filesystem-backed quality prefetch in this intermediate slice.
- [ ] Run `RIPWIRE_BIN=./build/ripwire bash test/redismcpcheck.sh`. Expected result: second MCP process reparses because `mcpCachePath` is still filesystem-only.
- [ ] Thread `std::shared_ptr<const CachePolicy>` through `runMcp`, `McpHttpConfig`, MCP dispatch state, and index state. Stdio/HTTP MCP may start without a root, so derive `CacheContext` only when each requested/watched root becomes known; never bake one root's project identity into server startup.
- [ ] Ensure each foreground rebuild constructs its own operation-local `RedisClient`. Share immutable policy, never a socket, parser buffer, or mutable reply object across threads.
- [ ] Keep watcher debounce, dirty-root invalidation, request ordering, and filesystem `mcpCachePath` behavior unchanged for non-Redis users.
- [ ] Run `RIPWIRE_BIN=./build/ripwire bash test/redismcpcheck.sh`, `test/mcpincrementalcheck.sh`, `test/mcpreloadcheck.sh`, `test/mcpwatchercheck.sh`, and `test/mcpframehonestycheck.sh`. Expected result: pass. Run `test/qsnapprefetchcheck.sh` in filesystem mode to prove its existing behavior is unchanged.
- [ ] Commit the MCP slice:

```bash
git add src/mcpindex.h src/mcp.h src/mcpserver.h src/main.cpp test/redismcpcheck.sh test/regression.sh
git commit -m "feat(cache): reuse Redis from MCP indexing"
```

## Task 6: Add a generic immutable blob store for derived caches

**Files:**

- Modify `src/cache_backend.h`
- Modify `src/redis_client.cpp`
- Modify `src/quality.h`
- Modify `src/gitoracle.h`
- Modify `src/mergescout.h`
- Modify `src/ingest_astquery.h`
- Modify `src/ingest_docpass.h`
- Modify `src/ingest.cpp`
- Modify `src/editcheck.h`
- Modify `src/mcpverbs.h`
- Modify `src/verbs_quality.h`
- Modify `src/verbs_change.h`
- Modify `src/mcpindex.h`
- Modify `src/mcp.h`
- Modify `src/mcpserver.h`
- Modify `src/main.cpp`
- Create `test/redisqualitycachecheck.sh`
- Modify `test/regression.sh`

**Done when:** immutable quality, Git-oracle, span-tier, and document-extraction blobs warm across distinct checkout paths through Redis; archived HEAD and merge-scout tree ingests reuse Task 4's record store; MCP quality prefetch is re-enabled with operation-local clients; local temp trees and lock files remain local.

**Out of scope:** Repo-authored notes/baselines/acks, edit/sidecar locks, temporary Git trees, remote clone directories, or changing any existing blob format.

- [ ] Add `test/redisqualitycachecheck.sh` first. For each family, assert checkout A's transcript contains miss then `SET`; checkout B contains a successful `GET`/TTL refresh, no replacement `SET`, and the existing cache-hit/prefetch observable; output equals `--no-cache`. Corrupt one value to force self-healing recomputation. Use private `TMPDIR`/`XDG_CACHE_HOME` and a complete before/after regular-file inventory, not a filename glob.
- [ ] Include explicit negative assertions that edit locks, sidecar locks, `materializeCommitTree` output, and cached remote clones still use local filesystem paths and are never sent as Redis values.
- [ ] Run `RIPWIRE_BIN=./build/ripwire bash test/redisqualitycachecheck.sh`. Expected result: fail because derived cache call sites still read local paths.
- [ ] Add a binary-safe address/result API:

```cpp
enum class CacheBlobFamily : std::uint8_t
{
    QualitySnapshot,
    QualityBody,
    QualityChurn,
    GitOracle,
    SpanTier,
    DocumentExtraction
};

struct CacheBlobAddress
{
    CacheBlobFamily family = CacheBlobFamily::QualitySnapshot;
    std::uint32_t schemeVersion = 0;
    std::uint8_t artifactArch = kArtifactArch;
    std::string identity;
    std::string localPath;
};

enum class CacheProbeStatus : std::uint8_t { Hit, Miss, Corrupt, Unavailable };
CacheProbeStatus probeCacheBlob( const CacheContext& cache, const CacheBlobAddress& address, std::string& bytes );
bool storeCacheBlob( const CacheContext& cache, const CacheBlobAddress& address, std::string_view bytes );
```

- [ ] Define `enum class CacheBlobFamily { QualitySnapshot, QualityBody, QualityChurn, GitOracle, SpanTier, DocumentExtraction }` and map it to closed fixed literals. Hash every external identity, cap the final key length, include `kArtifactArch` for native-layout formats, and test separators, braces, CR/LF, NUL, oversize, and foreign-architecture isolation.
- [ ] The file branch must call the current probe/atomic-write functions and preserve paths, bytes, alerts, and eviction. The Redis branch must `GET`/`SET ... EX`, enforce the 64 MiB ceiling, refresh TTL on a verified hit, and never touch `localPath`.
- [ ] Convert only opaque immutable families with their own codecs: `qsnap`, `qbody`, `qchurn`, Git oracle, span-tier memo, and document extraction. Keep their existing magic/scheme/parser/checksum validators as the authority; `CacheProbeStatus::Corrupt` triggers the current recompute path.
- [ ] Do **not** put `qheadsnap` or merge-scout ingest cache files through the generic blob API. `quality::computeHeadSnapshot` and `mergescout::indexCommittish` must derive an explicit archived-tree `CacheContext` from source project, commit SHA, excludes, mode, and crawl settings, then call Task 4's per-file record/descriptor backend. Materialized trees remain private local temp directories and are removed by existing guards.
- [ ] Thread `CachePolicy`/per-root `CacheContext` explicitly through `MainDispatch`, quality/change/edit verb entry points, `runMcp`/`McpHttpConfig`, MCP request dispatch, `computeHeadSnapshot`'s five direct callers, and `runDocPostPass`. Do not introduce process-global or thread-local ambient cache selection. Defaulted filesystem overloads preserve existing library call sites.
- [ ] Build logical identities from already-stable inputs (commit SHA, exclude/config hash, parser/cache version, relative path/content hash) plus namespace/project. Replace absolute-root components only in Redis keys; do not change filesystem keying in this task.
- [ ] Preserve the current HEAD snapshot mutex, but keep Redis network calls outside it when validation/order permits. Re-enable MCP snapshot prefetch only after both archived-tree ingest and final `qsnap` storage are Redis-aware. Each foreground/background operation builds its own client. Wait for the explicit prefetch completion observable and assert warm prefetch performs no replacement write.
- [ ] Run `RIPWIRE_BIN=./build/ripwire bash test/redisqualitycachecheck.sh`, `test/headsnapcachecheck.sh`, `test/qsnapcachecheck.sh`, `test/qchurnmemocheck.sh`, `test/historyoraclecheck.sh`, `test/mergescoutcheck.sh`, `test/docmdcachecheck.sh`, and `test/qsnapprefetchcheck.sh`. Expected result: pass.
- [ ] Commit the derived-cache slice:

```bash
git add src/cache_backend.h src/redis_client.cpp src/quality.h src/gitoracle.h src/mergescout.h src/ingest_astquery.h src/ingest_docpass.h src/ingest.cpp src/editcheck.h src/mcpverbs.h src/verbs_quality.h src/verbs_change.h src/mcpindex.h src/mcp.h src/mcpserver.h src/main.cpp test/redisqualitycachecheck.sh test/regression.sh
git commit -m "feat(cache): share immutable derived caches"
```

## Task 7: Make Redis health and redaction visible in doctor output

**Files:**

- Modify `src/verbs_doctor.h`
- Modify `src/cli.h`
- Create `test/redisdoctorcheck.sh`
- Modify `test/regression.sh`

**Done when:** `--doctor` verifies the configured Redis ACL can perform the actual cache command family, reports a comparable opaque scope fingerprint without exposing paths/endpoints/credentials, and marks partial capability as `ok="0"`.

**Out of scope:** Enumerating user cache keys, reporting memory usage, testing operator persistence/backup policy, or deleting anything except doctor's own short-lived random canary.

- [ ] Add `test/redisdoctorcheck.sh` first. Cover healthy Redis; ACLs missing `GET`, `MGET`, `SET`, `EXPIRE`, or `DEL`; refused remote plaintext; bad auth; timeout; malformed reply; unsupported cluster redirect; scope-fingerprint equality/difference; and endpoint/password/path sentinels that must not appear in XML or stderr.
- [ ] Run `RIPWIRE_BIN=./build/ripwire bash test/redisdoctorcheck.sh`. Expected result: Redis has no doctor row.
- [ ] Add a `cache_backend` doctor row. For Redis, `PING`, then use a cryptographically random key under the resolved scope to perform `SET ... NX EX 5`, `GET`, `MGET`, `EXPIRE`, and `DEL`; if cleanup is denied/fails, the five-second TTL remains the safety net. Emit stable attributes such as `kind="redis"`, `transport="loopback_tcp|unix"`, `db="selected"`, `scope="<16-hex fingerprint>"`, and `ok="0|1"`; emit a bounded categorical hint for missing capability/failure. Do not emit host, port, socket path, username, URL, server text, unhashed namespace, or project path.
- [ ] Update help text so users understand that Redis is disposable shared cache data, not source-of-truth storage, and that an unreachable Redis run recomputes without local persistence.
- [ ] Run `RIPWIRE_BIN=./build/ripwire bash test/redisdoctorcheck.sh`, `test/doctorcheck.sh`, `test/xmlwellformed.sh`, `test/jsonredactcheck.sh`, `test/mcpredactcheck.sh`, and `test/sigredactcheck.sh`. Expected result: pass.
- [ ] Commit the diagnostics slice:

```bash
git add src/verbs_doctor.h src/cli.h test/redisdoctorcheck.sh test/regression.sh
git commit -m "feat(doctor): report Redis cache health"
```

## Task 8: Validate TTL, memory bounds, and real Redis compatibility

**Files:**

- Create `test/redisrealcheck.sh`
- Modify `.github/workflows/ci.yml` (or the workflow that currently owns Linux regression execution)
- Modify `test/regression.sh`

**Done when:** the deterministic fixture proves TTL/limit behavior and CI proves compatibility with a real supported Redis server.

**Out of scope:** Shipping Redis, choosing server persistence/eviction settings, Redis Cluster, or benchmarking a remote production network.

- [ ] Extend fixture assertions for default TTL, configured TTL, TTL refresh after successful hits, active-descriptor survival, deleted/long-excluded descriptor expiry, orphan-record expiry, failed-record non-publication, maximum legal value, 64 MiB+1 refusal, outbound/reply aggregate ceilings, slow-drip/non-reader absolute deadlines, and bounded batch-local degradation.
- [ ] Add `test/redisrealcheck.sh` plus a Python-stdlib RESP admin helper for a real server. Generate a cryptographically random namespace prefix, record every exact key created, run cross-checkout cold/warm/edit/concurrency scenarios, inspect `TTL`/`TYPE`, and clean only recorded matching keys with bounded `SCAN` plus `UNLINK`/`DEL`. Never call `KEYS` or `FLUSHDB` on a user-provided server. Skip with a clear reason outside CI when no test server URL is provided.
- [ ] Register the fixture-only portion in `test/regression.sh`; keep the external real-server leg explicitly selected so ordinary disconnected regression runs do not require Redis.
- [ ] Run the fixture gate. Expected result before completing TTL logic: it fails on missing refresh/ceiling assertions.
- [ ] Add a separate Ubuntu CI job with health check and the amd64 service image `redis:7.4.5-alpine@sha256:0302cccee2b2043e61b497c8f4075467c5f7ba27a9f38be7e092634f2734baed`. Configure a dedicated ACL user restricted to the random ripwire prefix and required production commands, then run `bash test/redisrealcheck.sh`. Test partial ACL failure separately. Do not install `redis-cli` as a ripwire runtime dependency; CI-owned ephemeral setup may use the service's bundled administration tool.
- [ ] Run locally against an already available Redis only if one is present and explicitly disposable; otherwise rely on the CI service test. Do not start Docker locally without separate user authorization.
- [ ] Commit the compatibility slice:

```bash
git add test/redisrealcheck.sh test/regression.sh .github/workflows/ci.yml
git commit -m "test(cache): verify real Redis compatibility"
```

## Task 9: Document operation, migration, and stored data

**Files:**

- Modify `README.md`
- Modify `SECURITY.md`
- Modify `CHANGELOG.md`
- Regenerate `docs/COMMANDS.md`

**Done when:** a user can configure two computers safely, knows exactly what Redis stores, and can return to filesystem/no-cache operation without migration or data loss.

**Out of scope:** Managed Redis vendor instructions, automated SSH/Tailscale setup, backup guarantees, or treating cache data as durable user memory.

- [ ] Add a README example for both computers:

```bash
export RIPWIRE_CACHE_BACKEND=redis
export RIPWIRE_REDIS_URL=redis://127.0.0.1:6379/4
export RIPWIRE_REDIS_NAMESPACE=k0d3r1s
export RIPWIRE_REDIS_USERNAME=ripwire
export RIPWIRE_REDIS_PASSWORD='read-from-a-secret-manager'
ripwire . --for="trace cache invalidation"
```

- [ ] Document a complete loopback recipe: Redis 6.2+ bound to server loopback with protected mode; a dedicated `ripwire` ACL user limited to `~rw:v1:*` and `+ping +get +mget +set +expire +del +select`; and `ssh -N -L 6379:127.0.0.1:6379 user@redis-host` on each client. State exactly which namespace/project/mode variables must match.
- [ ] Document a separate encrypted-overlay recipe: bind Redis only to its Tailscale/private-overlay address, restrict the host firewall and Redis ACL, connect to that address, and set `RIPWIRE_REDIS_ALLOW_PLAINTEXT_REMOTE=1`. Explain that this opt-in relies on the overlay for encryption and must not be used on an ordinary LAN/Internet path.
- [ ] Explain how `RIPWIRE_REDIS_PROJECT` aligns repositories with different remotes and how `--no-cache` and `--cache=PATH` override the environment. Add a compatibility matrix: reuse requires matching namespace, derived project/crawl-root identity, cache/parser ABI, artifact architecture, and lean/rich mode. Different values remain correct but cold. Tell users to compare `--doctor` scope fingerprints on both computers.
- [ ] Add a per-family stored-data table covering logical key identity, exact value content, whether it includes plaintext or only hashes/coordinates, maximum value bound, sliding retention, and artifacts that remain local. Be explicit that ingest records contain relative paths, symbol/scope/include/binding/route names and coordinates, metrics, parse health, and lexical hashes but not complete source files; document extraction can contain full extracted document text; Git-derived families can contain commit/author/path metadata; all values should be treated as source-sensitive.
- [ ] Document Redis 6.2+ standalone support, RESP2, the production ACL command list, rough key scaling (one descriptor and one retained record per active path/content version plus derived blobs), 30-day sliding TTL, `maxmemory`/LRU-or-LFU eviction guidance, and that RDB/AOF may be disabled when operators accept cold rebuilds because every value is reconstructible. Clarify that enabling Redis persistence moves cache disk use to the Redis host.
- [ ] Document lifecycle honestly: the first Redis run is cold; enabling Redis does not migrate or remove old local caches; disabling it leaves Redis keys to expire; switching back may reuse still-valid local files. List local artifacts that remain (locks, temp Git trees during a run, remote clones, notes, baselines, acks). Provide a scoped, dry-run-first cleanup recipe based on the exact cache directory reported by `--doctor` and an allowlist of known persistent cache families; stop active ripwire processes before deletion and never remove the whole cache directory blindly.
- [ ] Document safe Redis cleanup: stop writers, copy the opaque hashed prefix shown by `--doctor`, run bounded `SCAN MATCH '<prefix>:*'`, review the count/sample, then `UNLINK`/`DEL` only those exact keys. Never use `KEYS` or `FLUSHDB`; concurrent clients may recreate keys. The application ACL does not need `SCAN`/`UNLINK`; use a separate administrative identity for cleanup.
- [ ] In `SECURITY.md`, state that parsed code metadata and derived text may be sensitive; fixed-width key hashes do not encrypt values; operators must provide access control, network encryption/tunneling, at-rest controls, and eviction appropriate to their threat model.
- [ ] Regenerate `docs/COMMANDS.md` from the built binary using the repository's existing command-doc generator; do not hand-edit generated flag text.
- [ ] Run `RIPWIRE_BIN=./build/ripwire bash test/readmedriftcheck.sh && RIPWIRE_BIN=./build/ripwire bash test/docscommandscheck.sh`. Expected result: pass.
- [ ] Commit documentation:

```bash
git add README.md SECURITY.md CHANGELOG.md docs/COMMANDS.md
git commit -m "docs(cache): document shared Redis storage"
```

## Task 10: Run the repository's full release gate

**Files:** Verification only; fix any failing source/test/documentation file and include it in the owning task's commit or a narrowly named follow-up commit.

**Done when:** all required normal, sanitizer, determinism, XML, and Redis tests pass; the tree contains no unexplained changes.

**Out of scope:** Ignoring a failure as pre-existing or weakening a gate to make it pass.

- [ ] Configure and build the normal development tree without `CMAKE_BUILD_TYPE=Release`:

```bash
cmake -S . -B build
cmake --build build -j
```

- [ ] Run the full parameterized gate:

```bash
python3 test/pargates.py . ./build/ripwire -j 6
```

- [ ] Configure and run the repository's sanitizer build and explicit heavy/safety gates:

```bash
cmake -S . -B asan -DRIPWIRE_ASAN=ON
cmake --build asan -j
cmake --build asan --target ripwire_asan_fixture
RIPWIRE_BIN=asan/ripwire bash test/packtaskcheck.sh
RIPWIRE_BIN=asan/ripwire bash test/tracecheck.sh
RIPWIRE_BIN=asan/ripwire bash test/qualitycheck.sh
RIPWIRE_BIN=asan/ripwire bash test/mergescoutcheck.sh
RIPWIRE_BIN=asan/ripwire bash test/editcheckcheck.sh
RIPWIRE_BIN=asan/ripwire RIPWIRE_ASAN_BIN=asan/ripwire bash test/cachefuzzcheck.sh
RIPWIRE_BIN=asan/ripwire bash test/cppqualcheck.sh
RIPWIRE_BIN=asan/ripwire bash test/redisclientcheck.sh
RIPWIRE_BIN=asan/ripwire bash test/redisingestcheck.sh
RIPWIRE_BIN=asan/ripwire bash test/redisqualitycachecheck.sh
```

Use the platform `ASAN_OPTIONS`, `UBSAN_OPTIONS`, and `LSAN_OPTIONS=suppressions=$PWD/lsan_suppressions.txt` values already pinned in `.github/workflows/ci.yml`; do not invent a weaker sanitizer profile.
- [ ] Run the determinism gate three times and XML well-formedness explicitly after the full suite, then repeat cross-checkout Redis output comparison with stdout hashes recorded by its gate:

```bash
RIPWIRE_BIN=build/ripwire bash test/det-gate.sh
RIPWIRE_BIN=build/ripwire bash test/det-gate.sh
RIPWIRE_BIN=build/ripwire bash test/det-gate.sh
RIPWIRE_BIN=build/ripwire bash test/xmlwellformed.sh
RIPWIRE_BIN=build/ripwire bash test/redisingestcheck.sh
```
- [ ] Run the real Redis CI leg and require it to pass before merge. A local Docker/image build is not part of this plan without explicit authorization.
- [ ] Run ripwire's change-quality gates:

```bash
ripwire . --quality-delta
ripwire . --test-gate
```

- [ ] Inspect `git status --short`, `git diff --check`, and the final commit range. Fix every failure, including failures not introduced by this work. Confirm no test secret, Redis credential, generated cache blob, socket, or fixture log is tracked.

## Acceptance checklist

- [ ] Filesystem is still the default, and its serialized cache bytes/output remain unchanged.
- [ ] Redis is genuinely record-level for ingest, not a monolithic cache-file upload.
- [ ] Separate absolute checkouts reuse records and derived immutable blobs.
- [ ] One changed/corrupt/missing file causes one reparse, not a cold rebuild.
- [ ] Redis mode creates no persistent local cache blob and never silently falls back to one.
- [ ] Redis errors cannot change stdout or make a correct result depend on cache availability.
- [ ] Secrets and endpoint details are absent from diagnostics and doctor output.
- [ ] Plaintext remote connections require explicit opt-in; TLS/Cluster rejection is clear.
- [ ] MCP foreground/background operations do not share sockets or parser state.
- [ ] Locks, temp trees, remote clones, notes, baselines, and acknowledgements remain local.
- [ ] TTLs refresh on use and bound abandoned records.
- [ ] Fixture, real Redis, existing regression, sanitizer, determinism, and XML gates pass.
