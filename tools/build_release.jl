using RomeoDB
import TOML

"""
    build_index_release(workdir, output; revision, registry, url_prefix,
                        previous = nothing, embedder = nothing, model = "none",
                        dimensions = 0, new_base = previous === nothing,
                        versions = RomeoDB.latest_versions(jll = true))

Build/update a dedicated public registry index, then stage the next package's
Artifacts.toml and IndexRelease.toml beside its archives. `registry` identifies
the pinned General revision used to select `versions`. `previous` is the prior
full snapshot directory, not a worker's patched database. An embedding model is
needed only on this builder, not on every worker.

This does not publish, change the package version, commit or push. Upload the
archives first; only then copy the staged bindings into the package and release
a new package version. Archives and bindings must be published together.
"""
function build_index_release(workdir::AbstractString, output::AbstractString;
                             revision::AbstractString, registry::AbstractString,
                             url_prefix::AbstractString, previous::Union{Nothing,AbstractString} = nothing,
                             embedder = nothing, model::AbstractString = "none", dimensions::Integer = 0,
                             new_base::Bool = previous === nothing,
                             function_embeddings::Bool = false, function_dimensions::Integer = 256,
                             versions = RomeoDB.latest_versions(jll = true),
                             stats::Bool = true,
                             previous_plan::AbstractString = joinpath(dirname(@__DIR__), "IndexRelease.toml"),
                             previous_bindings::AbstractString = joinpath(dirname(@__DIR__), "Artifacts.toml"),
                             progress = (done, total) -> nothing)
    occursin(r"^[A-Za-z0-9_.-]+$", revision) || error("Revision must be usable in an artifact filename")
    isempty(versions) && error("Refusing to publish an empty registry")
    isdir(output) && !isempty(readdir(output)) && error("Release output directory is not empty")
    mkpath(output)
    idx = RomeoDB.Index(workdir)
    counts = try
        isempty(RomeoDB.rows(idx, "SELECT * FROM localroots")) || error("Use a dedicated public builder without local roots")
        isempty(RomeoDB.rows(idx, "SELECT id FROM packages WHERE status = 'local'")) || error("Builder contains local packages")
        old = RomeoDB.releaseinfo(idx)
        if !isempty(old) && (old["model"] != model || old["dimensions"] != string(dimensions))
            RomeoDB.exec!(idx.db, "DELETE FROM vectors")
        end
        result = RomeoDB.update!(idx, versions; embedder, progress, stats, function_embeddings, function_dimensions)
        snapshot = joinpath(output, "snapshot")
        RomeoDB.release_snapshot!(idx, snapshot; revision, registry, model, dimensions)
        # Remember the recipe on the incremental builder too, so a model
        # change never leaves old vectors attached to unchanged source trees.
        RomeoDB.releaseinfo!(idx, Dict("schema" => "1", "revision" => revision,
            "registry" => registry, "model" => model, "dimensions" => string(dimensions), "kind" => "builder"))
        result
    finally
        RomeoDB.DBInterface.close!(idx.db)
    end

    bindings = joinpath(output, "Artifacts.toml")
    isfile(previous_bindings) && cp(previous_bindings, bindings)
    planfile = joinpath(output, "IndexRelease.toml")
    plan = isfile(previous_plan) ? TOML.parsefile(previous_plan) :
        Dict{String,Any}("format" => 1, "bases" => Any[], "patches" => Any[])
    !new_base && isempty(plan["bases"]) && error("The first release needs a base snapshot")
    snapshot = joinpath(output, "snapshot")
    archives = NamedTuple[]
    if previous !== nothing
        before, after = RomeoDB.Index(previous), RomeoDB.Index(snapshot)
        try
            old = RomeoDB.validate_release(before)
            !isempty(get(plan, "target", "")) && plan["target"] != old["revision"] &&
                error("Previous snapshot is not the package's current target")
            name = "registry-patch-$(old["revision"])-$revision"
            delta = RomeoDB.release_patch!(before, after, joinpath(output, "patch"))
            archive = joinpath(output, "$name.tar.gz")
            packed = RomeoDB.pack_release!(delta.path, name, archive, bindings; url = rstrip(url_prefix, '/') * "/$name.tar.gz")
            push!(archives, (; name, archive, packed..., changed = delta.changed, removed = delta.removed))
            push!(plan["patches"], Dict("from" => old["revision"], "to" => revision, "artifact" => name))
        finally
            RomeoDB.DBInterface.close!(before.db)
            RomeoDB.DBInterface.close!(after.db)
        end
    end
    if new_base
        name = "registry-base-$revision"
        archive = joinpath(output, "$name.tar.gz")
        packed = RomeoDB.pack_release!(snapshot, name, archive, bindings; url = rstrip(url_prefix, '/') * "/$name.tar.gz")
        push!(archives, (; name, archive, packed...))
        push!(plan["bases"], Dict("revision" => revision, "artifact" => name))
    end
    for archive in archives
        archive.bytes < 2^31 || error("$(archive.name) exceeds GitHub's release-asset limit")
    end
    plan["target"] = String(revision)
    open(io -> TOML.print(io, plan), planfile, "w")
    return (; revision, counts, archives, bindings, plan = planfile, snapshot)
end
