# Index releases

An index update is a RomeoDB package release. Pkg selects the package version;
that version's `IndexRelease.toml` selects a target revision and its
`Artifacts.toml` binds immutable base and patch archives. There is no separate
latest-version catalog, network poller or background updater.

## Weekly build

Use a dedicated public builder with a persistent source cache. Pin General to
one registry tree before selecting versions, and retain the resulting complete
snapshot for the next week's comparison. Do not use a worker database containing
local projects as the incremental builder.

In an environment containing RomeoDB and, for semantic vectors, the artifact-backed
Qwen3EmbeddingRunner:

```julia
using RomeoDB, Qwen3EmbeddingRunner
include(joinpath(pkgdir(RomeoDB), "tools", "build_release.jl"))
m = qwen3embedding()
release = build_index_release("/build/registry", "/build/releases/2026-W45";
    revision = "2026-W45", registry = "<pinned-General-tree>",
    versions = RomeoDB.latest_versions(jll = true),
    previous = "/build/releases/2026-W44/snapshot",
    embedder = m, model = "<embedding-artifact-hash-and-retrieval-recipe>", dimensions = 1024,
    function_embeddings = true, function_dimensions = 256,
    url_prefix = "https://github.com/SimonDanisch/RomeoDB.jl/releases/download/index-2026-W45")
```

For the first release omit `previous`. To refresh the base, pass `new_base = true`;
the builder also emits the patch from the previous revision, preserving the
upgrade path for existing installations. Subsequent builds normally emit only
a patch. Unchanged package trees are reused; only packages without vectors are
embedded. A changed model identity invalidates the builder's existing vectors.
Schema/model changes require an explicitly designed migration; ordinary patches
must have matching schema, model and dimensions.

The staged output contains:

- `snapshot/romeo.sqlite`: a complete public database for the next build.
- `patch/romeo.sqlite`: records for changed packages, removal identifiers and
  refreshed popularity counts; no source cache or unchanged package definitions.
- One patch archive, plus a base archive for the first build or a base refresh.
- Updated `Artifacts.toml` and `IndexRelease.toml`, preserving historical bindings
  and upgrade paths.

Package fingerprints include definitions, dependencies, vectors and summaries,
so an extractor correction under the same source-tree hash also enters a patch.
The builder strips local packages and roots, checks SQLite integrity, vector
coverage and dimensions, checkpoints the database and enforces the release-asset
size limit. Its returned status counts include failed fetches and missing entry
points; review them and run the judged search evaluations before publishing.

## Publication

1. Upload the generated archives under their immutable release URLs. Never
   replace an existing archive with different contents.
2. Verify installation using an empty artifact store and the staged plan.
3. Copy the staged `Artifacts.toml` and `IndexRelease.toml` into RomeoDB and bump
   its patch version. Do not publish bindings before their downloads exist.
4. Pin the standalone RomeoDB package revision in the BonitoAgents worker release.
   RomeoDB has its own repository and release cadence; its revision is independent
   of the BonitoAgents source revision.

Publishing the artifacts and releasing the code are explicit operations. The
builder does not commit, push, create a PR or publish a release.

## Worker installation

The worker launches `RomeoDB.serve(dir; provision = true)`. Provisioning obtains
a process lock, reads the plan belonging to the installed package version and
resolves the required artifacts through Pkg.

An empty installation takes the newest base and any following patches. A managed
installation downloads only its missing patches, even when a newer base exists.
Already applied patches and cached archives are reused. All missing downloads
finish before patch application starts; download failure leaves the old index
unchanged, logs the failure and starts with that installed revision. A fresh
installation without any usable index reports the failure instead.

Each patch changes package records, FTS entries, vectors, popularity counts and
the installed revision in one SQLite transaction. An application failure rolls
that patch back; a later retry resumes from the last committed revision. Local
packages and indexing roots are preserved. Independently built indexes remain
unmanaged and are not replaced. Downgrades or missing patch routes report an
explicit error instead of silently installing a different base.

The source cache is not shipped. `definition` downloads a package's exact
registered tree on demand and caches it under a package lock. Ordinary search,
body comparison and package discovery use the database alone.

## Optional graph and model

Pass `graph_source` to the weekly builder to ship a precomputed graph and clusters
for that snapshot. They are a separate lazy artifact: normal searching does not
download them. `ecosystem_graph_path()` requests the raw graph bundle;
`ecosystem_data(idx)` resolves its stored source identities against the installed
database, including ids reassigned by patch application alongside local projects.
An older revision's graph is never silently reused for a newer index.

All index, graph and Qwen model bindings are lazy. MCP initialization and tool
discovery download none of them. The first tool call provisions the database;
the first semantic query starts the optional model loader. Existing package
sources remain on-demand downloads of their exact registered trees.

For standalone embedding use, call `RomeoDB.install_embedding_runtime!()` in the
project that will run RomeoDB, then start a fresh Julia process with
`RomeoDB.serve(dir; provision=true, embedder=RomeoDB.loadqwen3embedding)`.
The software sources are pinned in `EmbeddingRuntime.toml`; their installation
does not fetch the model weights. BonitoAgents performs this software provisioning
automatically before launching its MCP process. Set `romeodb_embeddings=false`
in the worker configuration for CPU-only operation. Headless workers use
`JULIA_GLFW_PLATFORM=null`.

No weekly schedule is activated by the package. Run the builder as part of the
weekly release preparation; publishing a future scheduled job requires a builder
with the GPU runtime and its persistent cache.
