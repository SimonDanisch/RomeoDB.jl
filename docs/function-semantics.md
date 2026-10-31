# Function meaning and ecosystem clusters

Function-level semantic similarity is separate from package embeddings and
structural clone detection. A function document contains its documentation and
complete implementation; it contains no owning package name or README. This
allows different algorithms and identifiers to be neighbours without merely
putting every function in a package near the same package summary.

## Build and resume

```julia
using RomeoDB, Qwen3EmbeddingRunner
idx = RomeoDB.Index("/path/to/index")
m = qwen3embedding()
RomeoDB.embed_functions!(idx, m; dimensions = 256)
# A bounded first run / selected repositories:
RomeoDB.embed_functions!(idx, m; packages = ["NNlib", "StatsBase"], limit = 1000)
RomeoDB.function_coverage(idx; model = RomeoDB.functionmodel(m), dimensions = 256)
```

The default selects functions and macros with at least 40 structural tokens,
excluding generated code. Smaller helpers can be included with `mintokens = 0`.
JLL wrapper definitions remain absent. Source files are cached per package during
the build; identical function documents can reuse a vector across packages.
Matching model/recipe records are skipped on resume. Changes to indexed packages
remove their old function vectors, so the next build recomputes them.

Qwen uses overlapping windows bounded by the exported graph's token capacity.
All tokens participate, including the tail of long functions; window vectors are
pooled and normalized. This is not a single long-context forward pass and can
lose relationships between distant chunks. The model identity records the
artifact tree, capacity and overlap policy. New-function queries use Qwen's
instruction-aware query format; stored functions use its document format.

Vectors use a normalized 256-dimensional prefix of Qwen's Matryoshka output and
Float16 storage (512 bytes per function before database overhead). At query time
they are converted to Float32 and normalized again. An index must contain one
coherent model/recipe/dimension profile; incompatible query models are rejected.

The weekly release builder accepts `function_embeddings = true` and
`function_dimensions = 256`. Public snapshots and package-level patches include
function vectors; applying a patch remaps definition ids as well as package ids.
Local function vectors are preserved and excluded from public snapshots.

## Find implementations from a new body

```julia
functions = RomeoDB.functionindex(idx; model = RomeoDB.functionmodel(m), dimensions = 256)
hits = RomeoDB.semantic_similar(idx, functions, m, code;
    purpose = "coordinate matrices", exclude = ["MyPackage"])
existing = RomeoDB.find_existing(idx, RomeoDB.sketches(idx), code, "coordinate matrices";
    function_semantic = RomeoDB.FunctionSemantic(m, functions))
```

The MCP tools `find_existing` and `similar_functionality` use the function index
when its embedder and vectors are available. Package embeddings are never silently
treated as function embeddings. Missing function coverage is reported explicitly.
The server owns the embedder on one thread, including chunked function queries.

## Build a graph and consolidation candidates

```julia
functions = RomeoDB.functionindex(idx; approximate = true,
    model = RomeoDB.functionmodel(m), dimensions = 256)
graph = RomeoDB.semantic_graph(functions; k = 10, minsimilarity = 0.7)
groups = RomeoDB.semantic_clusters(idx, functions; graph,
    minsimilarity = 0.8, minpackages = 2, maxsize = 100)
```

HNSW supplies approximate neighbours for bulk graph construction. Candidate
search is bounded even when package filters or thresholds reject neighbours;
recall is approximate. An exact matrix-vector search is available for interactive
queries and small reference datasets. Bulk exact all-pairs construction is refused
above 10,000 functions. Large graph construction is an offline/central operation,
not something to rebuild for every chat tool call.

`FunctionGraph.ids` maps graph positions to database definition ids. Each edge
contains source/target positions and cosine similarity. The graph can feed the
zoomable ecosystem GUI; `semantic_neighbors` retrieves a selected function's
neighbours without requiring GPU inference.

The default graph uses mutual cross-package neighbours. Consolidation groups use
complete-link merging: every pair must satisfy the grouping threshold. A bridge
between two neighbourhoods cannot silently merge unrelated functions. Each group
returns a representative function, members, owning packages and its minimum pair
similarity. Thresholds need calibration; these groups suggest related functionality,
not equivalent edge cases, types, mutation, performance or numerical behavior.

## Validation and coverage

`eval/function_semantics.jl` evaluates real Qwen retrieval in a deliberately bounded
public corpus and reports cross-package groups and distinct structural variants.
It does not measure full-registry recall. Inspect its source and query results
alongside its scores. The deterministic test embedder validates storage, filtering,
thread routing, graph construction and patch remapping; it is not evidence of
real-model semantic quality.

Building function embeddings is a separate, resumable corpus operation. A working
API or an embedded pilot does not imply that all ecosystem functions are indexed.

`tools/build_function_graph.jl` runs the public-only embedding build followed by
HNSW construction and graph/clustering output. Its graph uses portable little-endian
binary node ids and edges with a TOML header, not Julia object serialization.
`read_function_graph` loads that output without a GPU, so the GUI can consume a
completed graph rather than rebuilding neighbours on every launch.
