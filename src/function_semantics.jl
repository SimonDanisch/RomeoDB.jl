# SPDX-FileCopyrightText: 2026 Simon Danisch
# SPDX-License-Identifier: AGPL-3.0-or-later

# Function bodies have their own embedding space. Package vectors are not used
# as a substitute for function similarity.

"""Embed a complete function document. Implementations must not silently truncate it."""
embedfunction(embedder, text::AbstractString) = embeddocument(embedder, text)
embedfunctionquery(embedder, text::AbstractString) = embedfunction(embedder, text)

"""Stable identity of the function embedding model, including its long-input policy."""
function functionmodel end

functiontext(code::AbstractString, doc::AbstractString = "") =
    "Julia function\nDocumentation:\n$doc\nImplementation:\n$code"

function compact_function_vector(vector::AbstractVector, dimensions::Integer)
    0 < dimensions <= length(vector) || throw(ArgumentError("Invalid function embedding dimensions: $dimensions"))
    out = Float32.(vector[1:dimensions])
    all(isfinite, out) && sum(abs2, out) > 0 || throw(ArgumentError("Function embedding must be finite and nonzero"))
    return normalize!(out)
end

mutable struct FunctionSources
    package::String
    files::Dict{String,Vector{String}}
end
FunctionSources() = FunctionSources("", Dict{String,Vector{String}}())

function function_source(idx::Index, h::Hit, cache::FunctionSources)
    if cache.package != h.package
        empty!(cache.files)
        cache.package = h.package
    end
    lines = get!(cache.files, h.file) do
        readlines(sourcepath(idx, h))
    end
    return join(lines[h.line:min(end, h.line + h.nlines - 1)], "\n")
end

"""
    embed_functions!(idx, embedder; dimensions = 256, model = functionmodel(embedder),
                     packages = [], ids = [], limit = typemax(Int), mintokens = 40, ...)

Embed complete, non-generated function/macro bodies and documentation, not package
summaries. Store normalized Float16 vectors, keyed to model, recipe and source hash.
Resume by skipping matching records; reuse identical documents across repositories.
GPU work happens outside write transactions and batches are committed atomically.
"""
function embed_functions!(idx::Index, embedder; dimensions::Integer = 256,
                          model::AbstractString = functionmodel(embedder),
                          packages = String[], ids = Int[], limit::Integer = typemax(Int),
                          mintokens::Integer = 40, missing_only::Bool = true, batchsize::Integer = 32,
                          public_only::Bool = false,
                          progress = (done, total) -> nothing)
    dimensions > 0 && batchsize > 0 && limit >= 0 || throw(ArgumentError("Invalid embedding dimensions, batch size or limit"))
    isempty(model) && throw(ArgumentError("Function embedding model identity cannot be empty"))
    recipe = "julia-body-doc-v1"
    filters = " AND d.kind IN ('function', 'macro') AND d.generated = 0 AND d.ntokens >= ? AND p.status IN ('ok', 'local')"
    args = Any[mintokens]
    public_only && (filters *= " AND p.status = 'ok'")
    if !isempty(packages)
        filters *= " AND p.name IN ($(join(fill("?", length(packages)), ", ")))"
        append!(args, packages)
    end
    if !isempty(ids)
        filters *= " AND d.id IN ($(join(Int.(ids), ", ")))"
    end
    if missing_only
        filters *= " AND NOT EXISTS (SELECT 1 FROM function_vectors v WHERE v.definition = d.id AND v.model = ? AND v.recipe = ? AND v.dimensions = ?)"
        append!(args, (model, recipe, dimensions))
    end
    total = min(limit, only(rows(idx, "SELECT count(*) AS n FROM defs d JOIN packages p ON p.id = d.package WHERE 1=1$filters", Tuple(args))).n)
    cache = FunctionSources()
    done, cursor = 0, 0
    while done < total
        batch = rows(idx, """SELECT d.id, d.package AS package_id, p.name AS package, p.version, p.repo,
            d.module, d.kind, d.name, d.signature, d.doc, d.file, d.line, d.nlines, d.generated,
            0 AS exported, 0 AS users, p.status='local' AS islocal
            FROM defs d JOIN packages p ON p.id = d.package WHERE d.id > ?$filters ORDER BY d.id LIMIT ?""",
                     (cursor, args..., min(batchsize, total - done)))
        isempty(batch) && break
        pending = NamedTuple[]
        reused = Dict{String,Vector{UInt8}}()
        for row in batch
            hit = Hit(row)
            text = functiontext(function_source(idx, hit, cache), hit.doc)
            hash = bytes2hex(SHA.sha256(text))
            blob = get!(reused, hash) do
                previous = rows(idx, "SELECT vec FROM function_vectors WHERE model = ? AND recipe = ? AND dimensions = ? AND source_hash = ? LIMIT 1",
                                (model, recipe, dimensions, hash))
                isempty(previous) || return Vector{UInt8}(only(previous).vec)
                vector = compact_function_vector(embedfunction(embedder, text), dimensions)
                return collect(reinterpret(UInt8, Float16.(vector)))
            end
            push!(pending, (; id = hit.id, package = row.package_id, hash, blob))
        end
        SQLite.transaction(idx.db) do
            for item in pending
                exec!(idx.db, "INSERT OR REPLACE INTO function_vectors VALUES (?, ?, ?, ?, ?, ?, ?)",
                      (item.id, item.package, model, recipe, dimensions, item.hash, item.blob))
            end
        end
        cursor = last(batch).id
        done += length(pending)
        progress(done, total)
    end
    return done
end

"""Coverage is explicit: having package embeddings does not mean functions are embedded."""
function function_coverage(idx::Index; model::AbstractString, dimensions::Integer = 256, mintokens::Integer = 40,
                           public_only::Bool = false)
    status = public_only ? " AND p.status='ok'" : " AND p.status IN ('ok','local')"
    eligible = only(rows(idx, "SELECT count(*) AS n FROM defs d JOIN packages p ON p.id=d.package WHERE d.kind IN ('function','macro') AND d.generated=0 AND d.ntokens>=?$status", (mintokens,))).n
    embedded = only(rows(idx, "SELECT count(*) AS n FROM function_vectors v JOIN defs d ON d.id=v.definition JOIN packages p ON p.id=d.package WHERE v.model=? AND v.recipe='julia-body-doc-v1' AND v.dimensions=? AND d.ntokens>=? AND d.generated=0 AND d.kind IN ('function','macro')$status", (model, dimensions, mintokens))).n
    return (; eligible, embedded, missing = eligible - embedded, model = String(model), dimensions)
end

struct FunctionIndex{G}
    ids::Vector{Int}
    packages::Vector{Int}
    vectors::Matrix{Float32}
    model::String
    recipe::String
    graph::G
end

"""
    functionindex(idx; model = nothing, dimensions = nothing, approximate = false)

Load one coherent function embedding profile. Exact search uses matrix-vector
products; bulk clustering uses HNSW to avoid a quadratic all-pairs comparison.
"""
function functionindex(idx::Index; model::Union{Nothing,AbstractString} = nothing,
                       dimensions::Union{Nothing,Integer} = nothing, approximate::Bool = false,
                       public_only::Bool = false,
                       M::Integer = 16, ef::Integer = 100, progress = n -> nothing)
    where = " WHERE recipe = 'julia-body-doc-v1'"
    args = Any[]
    public_only && (where *= " AND package IN (SELECT id FROM packages WHERE status='ok')")
    model === nothing || (where *= " AND model = ?"; push!(args, model))
    dimensions === nothing || (where *= " AND dimensions = ?"; push!(args, dimensions))
    profiles = rows(idx, "SELECT DISTINCT model, recipe, dimensions FROM function_vectors$where", Tuple(args))
    isempty(profiles) && error("No function embeddings for the requested profile; package vectors do not provide function similarity")
    length(profiles) == 1 || error("Several function embedding profiles exist; specify model and dimensions")
    profile = only(profiles)
    n = only(rows(idx, "SELECT count(*) AS n FROM function_vectors$where", Tuple(args))).n
    ids, packages = Vector{Int}(undef, n), Vector{Int}(undef, n)
    vectors = Matrix{Float32}(undef, profile.dimensions, n)
    result = DBInterface.execute(idx.db, "SELECT definition, package, vec FROM function_vectors$where ORDER BY definition", Tuple(args))
    try
        for (i, row) in enumerate(result)
            ids[i], packages[i] = row.definition, row.package
            vectors[:, i] .= reinterpret(Float16, row.vec)
            normalize!(view(vectors, :, i))
        end
    finally
        DBInterface.close!(result)
    end
    graph = if approximate
        hnsw = HNSW.HierarchicalNSW(collect(eachcol(vectors)); metric = HNSW.CosineDist(), M, efConstruction = max(100, ef), ef)
        HNSW.add_to_graph!(progress, hnsw)
        hnsw
    else
        nothing
    end
    return FunctionIndex(ids, packages, vectors, profile.model, profile.recipe, graph)
end

function function_nearest(index::FunctionIndex, query::AbstractVector; limit::Integer = 10,
                          minsimilarity::Real = 0.5, exclude = Int[], self::Integer = 0,
                          max_candidates::Integer = max(128, 16limit))
    limit > 0 && -1 <= minsimilarity <= 1 || throw(ArgumentError("Invalid function search limit or threshold"))
    n = length(index.ids)
    q = compact_function_vector(query, size(index.vectors, 1))
    if index.graph === nothing
        scores = index.vectors' * q
        for i in eachindex(scores)
            (index.ids[i] == self || index.packages[i] in exclude) && (scores[i] = -Inf32)
        end
        candidates = partialsortperm(scores, 1:min(limit, n); rev = true)
        return [(i, clamp(scores[i], -1f0, 1f0)) for i in candidates if scores[i] >= minsimilarity]
    end
    # Over-fetch and expand when filters hide close neighbours from one package.
    cap = min(n, max(limit, max_candidates))
    count = min(cap, max(4limit, 32))
    while true
        candidates = first(HNSW.knn_search(index.graph, q, count))
        matches = Tuple{Int,Float32}[]
        for i in candidates
            index.ids[i] == self && continue
            index.packages[i] in exclude && continue
            score = clamp(dot(view(index.vectors, :, i), q), -1f0, 1f0)
            score >= minsimilarity && push!(matches, (Int(i), score))
        end
        sort!(matches; by = last, rev = true)
        (length(matches) >= limit || count == cap) && return first(matches, min(limit, length(matches)))
        count = min(cap, 2count)
    end
end

struct SemanticFunctionHit
    definition::Hit
    similarity::Float32
end

struct FunctionSemantic{E,I<:FunctionIndex}
    embedder::E
    index::I
end

function semantic_neighbors(idx::Index, index::FunctionIndex, id::Integer; limit::Integer = 10,
                            minsimilarity::Real = 0.5, exclude = String[], cross_packages::Bool = false)
    position = searchsortedfirst(index.ids, id)
    position <= length(index.ids) && index.ids[position] == id || error("Definition $id has no function embedding in this index")
    excluded = packageids(idx, exclude)
    cross_packages && push!(excluded, index.packages[position])
    matches = function_nearest(index, view(index.vectors, :, position); limit, minsimilarity, exclude = excluded, self = id)
    return [SemanticFunctionHit(definition(idx, index.ids[i]), score) for (i, score) in matches]
end

"""Search by complete new function bodies, including different implementations of a task."""
function semantic_similar(idx::Index, index::FunctionIndex, embedder, code::AbstractString;
                          purpose::AbstractString = "", limit::Integer = 10, minsimilarity::Real = 0.5,
                          exclude = String[])
    index.model == functionmodel(embedder) || error("Query embedder does not match the indexed function model")
    parsed = extract_code(code)
    defs = filter(d -> d.kind in (:function, :macro), parsed.defs)
    isempty(defs) && throw(ArgumentError("Submit complete function or macro definitions for semantic comparison"))
    lines = split(code, '\n')
    excluded = packageids(idx, exclude)
    return map(defs) do d
        body = join(lines[d.line:min(end, d.line + d.nlines - 1)], "\n")
        text = functiontext(body, join(filter(!isempty, [d.doc, String(purpose)]), "\n"))
        vector = embedfunctionquery(embedder, text)
        matches = function_nearest(index, vector; limit, minsimilarity, exclude = excluded)
        (; query = d, hits = [SemanticFunctionHit(definition(idx, index.ids[i]), score) for (i, score) in matches])
    end
end

struct FunctionEdge
    source::Int                 # positions in FunctionGraph.ids
    target::Int
    similarity::Float32
end

struct FunctionGraph
    ids::Vector{Int}
    edges::Vector{FunctionEdge}
    model::String
    dimensions::Int
    approximate::Bool
end

"""Write a portable little-endian graph; does not serialize Julia objects or code."""
function write_function_graph(dir::AbstractString, graph::FunctionGraph)
    length(graph.ids) <= typemax(UInt32) || throw(ArgumentError("Function graph exceeds the UInt32 node format"))
    mkpath(dir)
    open(joinpath(dir, "ids.bin"), "w") do io
        for id in graph.ids
            write(io, htol(Int64(id)))
        end
    end
    open(joinpath(dir, "edges.bin"), "w") do io
        for edge in graph.edges
            write(io, htol(UInt32(edge.source)), htol(UInt32(edge.target)), htol(reinterpret(UInt32, edge.similarity)))
        end
    end
    open(joinpath(dir, "graph.toml"), "w") do io
        TOML.print(io, Dict("format" => 1, "nodes" => length(graph.ids), "edges" => length(graph.edges),
            "model" => graph.model, "dimensions" => graph.dimensions, "approximate" => graph.approximate))
    end
    return String(dir)
end

function read_function_graph(dir::AbstractString)
    info = TOML.parsefile(joinpath(dir, "graph.toml"))
    info["format"] == 1 || error("Unsupported function graph format")
    ids = open(joinpath(dir, "ids.bin")) do io
        [Int(ltoh(read(io, Int64))) for _ in 1:info["nodes"]]
    end
    edges = open(joinpath(dir, "edges.bin")) do io
        [FunctionEdge(Int(ltoh(read(io, UInt32))), Int(ltoh(read(io, UInt32))),
            reinterpret(Float32, ltoh(read(io, UInt32)))) for _ in 1:info["edges"]]
    end
    all(e -> 1 <= e.source < e.target <= length(ids) && isfinite(e.similarity), edges) || error("Invalid function graph edges")
    return FunctionGraph(ids, edges, info["model"], info["dimensions"], info["approximate"])
end

"""A mutual-kNN graph of function meaning, suitable for an ecosystem map."""
function semantic_graph(index::FunctionIndex; k::Integer = 10, minsimilarity::Real = 0.7,
                        mutual::Bool = true, cross_packages::Bool = true,
                        progress = (done, total) -> nothing)
    n = length(index.ids)
    index.graph === nothing && n > 10_000 && error("Build functionindex(...; approximate=true) for ecosystem-scale clustering")
    neighbours = Vector{Vector{Tuple{Int,Float32}}}(undef, n)
    for i in 1:n
        excluded = cross_packages ? [index.packages[i]] : Int[]
        neighbours[i] = function_nearest(index, view(index.vectors, :, i); limit = k, minsimilarity,
            self = index.ids[i], exclude = excluded)
        progress(i, n)
    end
    edges = FunctionEdge[]
    for i in 1:n, (j, score) in neighbours[i]
        reciprocal = any(p -> first(p) == i, neighbours[j])
        if mutual
            i < j && reciprocal || continue
        else
            i > j && reciprocal && continue
        end
        push!(edges, FunctionEdge(min(i, j), max(i, j), score))
    end
    return FunctionGraph(copy(index.ids), edges, index.model, size(index.vectors, 1), index.graph !== nothing)
end

"""
    semantic_clusters(idx, index; graph = semantic_graph(index), minsimilarity = 0.8, ...)

Candidate groups across packages. Complete-link merging requires EVERY pair in a
group to meet the threshold; a chain of weaker neighbours cannot merge unrelated
functions. This is evidence of related functionality, not behavioural equivalence.
"""
function semantic_clusters(idx::Index, index::FunctionIndex; graph::FunctionGraph = semantic_graph(index),
                           minsimilarity::Real = 0.8, minpackages::Integer = 2,
                           maxsize::Integer = 100, limit::Integer = 100)
    -1 <= minsimilarity <= 1 && minpackages > 0 && maxsize >= 2 && limit >= 0 || throw(ArgumentError("Invalid semantic clustering parameters"))
    graph.ids == index.ids && graph.model == index.model && graph.dimensions == size(index.vectors, 1) || error("Function graph and vector index disagree")
    parent = collect(eachindex(index.ids))
    members = Dict{Int,Vector{Int}}()
    function root(i)
        while parent[i] != i
            parent[i] = parent[parent[i]]
            i = parent[i]
        end
        return i
    end
    for edge in sort(graph.edges; by = e -> e.similarity, rev = true)
        edge.similarity >= minsimilarity || continue
        a, b = root(edge.source), root(edge.target)
        a == b && continue
        left, right = get(members, a, [a]), get(members, b, [b])
        length(left) + length(right) <= maxsize || continue
        all(dot(view(index.vectors, :, i), view(index.vectors, :, j)) >= minsimilarity for i in left for j in right) || continue
        parent[b] = a
        members[a] = [left; right]
        delete!(members, b)
    end
    groups = NamedTuple[]
    for indices in values(members)
        length(unique(index.packages[indices])) >= minpackages || continue
        vectors = view(index.vectors, :, indices)
        means = vec(sum(vectors' * vectors; dims = 2))
        representative = indices[argmax(means)]
        hits = [definition(idx, index.ids[i]) for i in indices]
        minimum_similarity = clamp(minimum(dot(view(index.vectors, :, i), view(index.vectors, :, j)) for i in indices for j in indices), -1f0, 1f0)
        push!(groups, (; representative = definition(idx, index.ids[representative]), members = hits,
            packages = sort!(unique(h.package for h in hits)), minimum_similarity))
    end
    sort!(groups; by = g -> (length(g.packages), length(g.members), g.minimum_similarity), rev = true)
    return first(groups, min(limit, length(groups)))
end
