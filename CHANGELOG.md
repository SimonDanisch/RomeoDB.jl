# Changelog

## 0.1.0

- Standalone Julia package, licensed under AGPL-3.0-or-later, with a CPU-only core
  and an optional artifact-backed Qwen embedding runtime.
- Package discovery, dependency exploration, structural function comparison, and
  semantic searches of complete function bodies.
- Lazy registry database and optional ecosystem graph artifacts. Installation,
  importing the package, and MCP initialization do not download ecosystem data.
- Version-pinned snapshots and incremental package patches, preserving local
  indexing roots and local packages when applying updates.
- Portable function similarity graphs and consolidation candidate clusters,
  with source identities that survive database id reassignment during patching.
- Exact registered package source trees fetched on demand for source inspection.
- Separate CPU and Lavapipe Vulkan embedding CI jobs.

The first snapshot includes 14,622 searchable registered packages and 766,325
public function embeddings. Its optional graph contains 1,209,807 similarity
edges and 93,229 cross-package candidate groups. These are similarity candidates,
not proofs of behavioral equivalence. The snapshot exports the cached package
trees indexed on 2026-10-31; it reports 15 fetch failures and 2 missing entry points.

Install from the repository until General registration is completed:

```julia
using Pkg
Pkg.add(url = "https://github.com/SimonDanisch/RomeoDB.jl")
```
