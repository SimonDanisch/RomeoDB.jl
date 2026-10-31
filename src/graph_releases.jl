# SPDX-FileCopyrightText: 2026 Simon Danisch
# SPDX-License-Identifier: AGPL-3.0-or-later

# A graph's vertex positions are stable, but SQLite row ids can change when a
# worker applies package patches alongside local projects. Bind vertices to
# registered source locations, then resolve ids against the installed database.
function graph_keys(idx::Index, graph::FunctionGraph)
    records = rows(idx, """SELECT d.id, p.uuid, p.tree, d.file, d.line, d.name
        FROM function_vectors v JOIN defs d ON d.id=v.definition
        JOIN packages p ON p.id=d.package
        WHERE p.status='ok' AND v.model=? AND v.dimensions=? AND v.recipe='julia-body-doc-v1'""",
        (graph.model, graph.dimensions))
    return Dict(r.id => Tuple(SHA.sha256(JSON3.write((r.uuid, r.tree, r.file, r.line, r.name)))) for r in records)
end

"""Stage a portable public graph, clusters and source identities for release."""
function stage_graph_release!(idx::Index, source::AbstractString, dest::AbstractString;
                              revision::AbstractString)
    validate_release(idx)["revision"] == revision || error("Graph revision differs from the snapshot")
    graph = read_function_graph(source)
    keys = graph_keys(idx, graph)
    all(id -> haskey(keys, id), graph.ids) || error("Graph includes functions absent from the public snapshot")
    isdir(dest) && !isempty(readdir(dest)) && error("Graph release destination must be empty")
    mkpath(dest)
    for file in ("ids.bin", "edges.bin", "graph.toml", "clusters.toml")
        cp(joinpath(source, file), joinpath(dest, file))
    end
    metadata = TOML.parsefile(joinpath(dest, "graph.toml"))
    metadata["index_revision"] = String(revision)
    open(io -> TOML.print(io, metadata), joinpath(dest, "graph.toml"), "w")
    open(joinpath(dest, "identity_keys.bin"), "w") do io
        for id in graph.ids
            write(io, collect(keys[id]))
        end
    end
    return String(dest)
end

"""Archive the staged graph as a lazy artifact, independently of the database."""
function pack_graph_release!(dir::AbstractString, name::AbstractString, archive::AbstractString,
                             bindings::AbstractString; url::AbstractString)
    metadata = TOML.parsefile(joinpath(dir, "graph.toml"))
    filesize(joinpath(dir, "identity_keys.bin")) == 32 * metadata["nodes"] || error("Invalid graph identity keys")
    hash = Artifacts.create_artifact() do root
        for file in ("ids.bin", "edges.bin", "graph.toml", "clusters.toml", "identity_keys.bin")
            cp(joinpath(dir, file), joinpath(root, file))
        end
    end
    if isfile(bindings)
        old = Artifacts.artifact_hash(String(name), String(bindings))
        old === nothing || old == hash || error("Graph artifact name already binds different content")
    end
    mkpath(dirname(abspath(archive)))
    sha = Artifacts.archive_artifact(hash, archive)
    Artifacts.bind_artifact!(bindings, String(name), hash;
        download_info = [(String(url), sha)], lazy = true, force = true)
    return (; hash, sha256 = sha, bytes = filesize(archive))
end

"""Download the optional ecosystem graph only when requested. No GPU is needed."""
function ecosystem_graph_path(; plan::AbstractString = joinpath(@__DIR__, "..", "IndexRelease.toml"),
                               bindings::AbstractString = joinpath(@__DIR__, "..", "Artifacts.toml"))
    release = index_plan(plan)
    spec = release["graph"]
    spec["revision"] == release["target"] || error("Graph does not belong to this index release")
    dir = release_asset(spec["artifact"], bindings)
    TOML.parsefile(joinpath(dir, "graph.toml"))["index_revision"] == release["target"] || error("Graph revision mismatch")
    return dir
end

"""Load graph and groups, resolving source identities against a materialized index."""
function ecosystem_data(idx::Index; plan::AbstractString = joinpath(@__DIR__, "..", "IndexRelease.toml"),
                                  bindings::AbstractString = joinpath(@__DIR__, "..", "Artifacts.toml"))
    releaseinfo(idx)["revision"] == index_plan(plan)["target"] || error("Index and ecosystem graph revisions differ")
    dir = ecosystem_graph_path(; plan, bindings)
    graph = read_function_graph(dir)
    current = Dict(key => id for (id, key) in graph_keys(idx, graph))
    keys = open(joinpath(dir, "identity_keys.bin")) do io
        [Tuple(read(io, 32)) for _ in graph.ids]
    end
    all(key -> haskey(current, key), keys) || error("Graph source locations are missing from the index")
    ids = [current[key] for key in keys]
    length(unique(ids)) == length(ids) || error("Graph source identities are ambiguous")
    translation = Dict(zip(graph.ids, ids))
    order = sortperm(ids)
    positions = invperm(order)
    edges = [FunctionEdge(min(positions[e.source], positions[e.target]),
        max(positions[e.source], positions[e.target]), e.similarity) for e in graph.edges]
    mapped = FunctionGraph(ids[order], edges, graph.model, graph.dimensions, graph.approximate)
    groups = TOML.parsefile(joinpath(dir, "clusters.toml"))["groups"]
    for group in groups
        group["representative"] = translation[group["representative"]]
        group["members"] = [translation[id] for id in group["members"]]
    end
    return (; graph = mapped, groups)
end
