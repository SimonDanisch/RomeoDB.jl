# SPDX-FileCopyrightText: 2026 Simon Danisch
# SPDX-License-Identifier: AGPL-3.0-or-later

# Public index releases are immutable artifacts. Only the materialized index is
# writable; its revision changes in the same transaction as its package records.

releaseinfo(idx::Index) = Dict(String(r.key) => String(r.value) for r in rows(idx, "SELECT key, value FROM index_release"))

function releaseinfo!(idx::Index, info::AbstractDict)
    exec!(idx.db, "DELETE FROM index_release")
    for (key, value) in info
        exec!(idx.db, "INSERT INTO index_release VALUES (?, ?)", (String(key), String(value)))
    end
end

function tablecolumns(idx::Index, table::String; omit = ())
    join((r.name for r in rows(idx, "PRAGMA table_info($table)") if r.name ∉ omit), ", ")
end

function package_digest(idx::Index, id::Integer)
    ctx = SHA.SHA2_256_CTX()
    for table in ("packages", "defs", "exports", "deps", "vectors", "function_vectors", "problems")
        columns = tablecolumns(idx, table; omit = ("id", "package", "definition"))
        key = table == "packages" ? "id" : "package"
        SHA.update!(ctx, codeunits(table))
        for row in DBInterface.execute(idx.db, "SELECT $columns FROM $table WHERE $key = ? ORDER BY rowid", (id,))
            # Ignore database row ids: local packages and previous patches may
            # have assigned different ids to the same public package.
            SHA.update!(ctx, codeunits(JSON3.write(NamedTuple(row))))
            SHA.update!(ctx, UInt8[0x0a])
        end
    end
    return bytes2hex(SHA.digest!(ctx))
end

function fingerprint_packages!(idx::Index)
    exec!(idx.db, "DELETE FROM release_packages")
    for p in rows(idx, "SELECT id, uuid FROM packages WHERE status != 'local' ORDER BY uuid")
        exec!(idx.db, "INSERT INTO release_packages VALUES (?, ?)", (p.uuid, package_digest(idx, p.id)))
    end
end

function validate_release(idx::Index)
    info = releaseinfo(idx)
    info["schema"] == "1" || error("Unsupported index schema $(info["schema"])")
    only(rows(idx, "PRAGMA integrity_check")).integrity_check == "ok" || error("Index integrity check failed")
    only(rows(idx, "SELECT count(*) AS n FROM localroots")).n == 0 || error("Release contains local indexing roots")
    only(rows(idx, "SELECT count(*) AS n FROM packages WHERE status = 'local'")).n == 0 || error("Release contains local packages")
    for table in ("defs", "exports", "deps", "vectors", "function_vectors", "problems")
        only(rows(idx, "SELECT count(*) AS n FROM $table c LEFT JOIN packages p ON p.id = c.package WHERE p.id IS NULL")).n == 0 ||
            error("Release contains orphaned $table records")
    end
    nv = only(rows(idx, "SELECT count(*) AS n FROM vectors")).n
    only(rows(idx, "SELECT count(*) AS n FROM function_vectors v LEFT JOIN defs d ON d.id=v.definition WHERE d.id IS NULL OR d.package!=v.package OR v.dimensions<=0 OR length(v.vec)!=2*v.dimensions")).n == 0 ||
        error("Release contains invalid function vectors")
    if info["model"] != "none"
        np = only(rows(idx, "SELECT count(*) AS n FROM packages WHERE status = 'ok'")).n
        nv == np || error("Release has $nv vectors for $np searchable packages")
        lengths = rows(idx, "SELECT DISTINCT length(vec) AS n FROM vectors")
        all(r -> r.n == parse(Int, info["dimensions"]) * sizeof(Float32), lengths) || error("Embedding dimensions disagree")
    else
        nv == 0 || error("A release with vectors must identify its embedding model")
    end
    return info
end

"""
    release_snapshot!(source, dest; revision, registry, model = "none", dimensions = 0)

Create a compact public-only snapshot in `dest`. `registry` is the General revision;
`model` identifies the embedding artifact and retrieval recipe. Never copies local
packages, roots or their vectors. The source must not be modified during the build.
"""
function release_snapshot!(source::Index, dest::AbstractString; revision::AbstractString,
                           registry::AbstractString, model::AbstractString = "none", dimensions::Integer = 0)
    isfile(joinpath(dest, "romeo.sqlite")) && error("Release destination already contains an index: $dest")
    out = Index(dest)
    try
        exec!(out.db, "ATTACH DATABASE ? AS incoming", (abspath(joinpath(source.dir, "romeo.sqlite")),))
        try
            SQLite.transaction(out.db) do
                exec!(out.db, "INSERT INTO packages SELECT * FROM incoming.packages WHERE status != 'local'")
                for table in ("defs", "exports", "deps", "vectors", "function_vectors", "problems")
                    exec!(out.db, "INSERT INTO $table SELECT c.* FROM incoming.$table c JOIN main.packages p ON p.id = c.package")
                end
                exec!(out.db, "INSERT INTO downloads SELECT d.* FROM incoming.downloads d WHERE d.uuid IN (SELECT uuid FROM main.packages)")
                releaseinfo!(out, Dict("schema" => "1", "revision" => revision, "registry" => registry,
                    "model" => model, "dimensions" => string(dimensions), "kind" => "base"))
            end
        finally
            exec!(out.db, "DETACH DATABASE incoming")
        end
        reindex_text!(out)
        fingerprint_packages!(out)
        validate_release(out)
        exec!(out.db, "PRAGMA wal_checkpoint(TRUNCATE)")
        exec!(out.db, "VACUUM")
    finally
        DBInterface.close!(out.db)
    end
    return String(dest)
end

"""Build a package-level delta between two validated public snapshots."""
function release_patch!(before::Index, after::Index, dest::AbstractString)
    old, new = validate_release(before), validate_release(after)
    for key in ("schema", "model", "dimensions")
        old[key] == new[key] || error("Cannot patch across different $key values; publish a compatible base")
    end
    old["revision"] != new["revision"] || error("Patch revisions must differ")
    isfile(joinpath(dest, "romeo.sqlite")) && error("Patch destination already contains an index")
    a = Dict(r.uuid => r.digest for r in rows(before, "SELECT * FROM release_packages"))
    b = Dict(r.uuid => r.digest for r in rows(after, "SELECT * FROM release_packages"))
    changed = sort!([uuid for (uuid, digest) in b if get(a, uuid, nothing) != digest])
    removed = sort!([uuid for uuid in keys(a) if !haskey(b, uuid)])
    out = Index(dest)
    try
        exec!(out.db, "CREATE TABLE removed (uuid TEXT PRIMARY KEY)")
        exec!(out.db, "ATTACH DATABASE ? AS incoming", (abspath(joinpath(after.dir, "romeo.sqlite")),))
        try
            SQLite.transaction(out.db) do
                for uuid in changed
                    exec!(out.db, "INSERT INTO packages SELECT * FROM incoming.packages WHERE uuid = ?", (uuid,))
                end
                for table in ("defs", "exports", "deps", "vectors", "function_vectors", "problems")
                    exec!(out.db, "INSERT INTO $table SELECT c.* FROM incoming.$table c JOIN main.packages p ON p.id = c.package")
                end
                exec!(out.db, "INSERT INTO release_packages SELECT c.* FROM incoming.release_packages c JOIN main.packages p ON p.uuid = c.uuid")
                # Popularity counts are small and change independently of source trees.
                exec!(out.db, "INSERT INTO downloads SELECT * FROM incoming.downloads")
                for uuid in removed
                    exec!(out.db, "INSERT INTO removed VALUES (?)", (uuid,))
                end
                releaseinfo!(out, merge(new, Dict("kind" => "patch", "from" => old["revision"])))
            end
        finally
            exec!(out.db, "DETACH DATABASE incoming")
        end
        exec!(out.db, "PRAGMA wal_checkpoint(TRUNCATE)")
        exec!(out.db, "VACUUM")
    finally
        DBInterface.close!(out.db)
    end
    return (; path = String(dest), changed = length(changed), removed = length(removed))
end

# These expressions match reindex_text!. Contentless FTS5 needs the old values
# to delete a row, so read them BEFORE replacing package records.
function package_document(idx::Index, id::Integer)
    only(rows(idx, """SELECT p.id, p.name,
        (SELECT group_concat(doc, ' ') FROM defs WHERE package = p.id AND kind IN ('readme', 'module')) AS about,
        (SELECT substr(group_concat(doc, ' '), 1, 100000) FROM defs WHERE package = p.id AND kind = 'docs') AS docs,
        (SELECT substr(group_concat(words || ' ' || substr(doc, 1, 200), ' '), 1, 100000) FROM defs
            WHERE package = p.id AND kind NOT IN ('readme', 'module', 'docs')) AS api
        FROM packages p WHERE id = ?""", (id,)))
end

function package_fts!(idx::Index, id::Integer; delete::Bool = false)
    p = package_document(idx, id)
    command = delete ? "INSERT INTO packages_fts(packages_fts, rowid, name, about, docs, api) VALUES ('delete', ?, ?, ?, ?, ?)" :
                       "INSERT INTO packages_fts(rowid, name, about, docs, api) VALUES (?, ?, ?, ?, ?)"
    exec!(idx.db, command, (p.id, p.name * " " * namewords(p.name), p.about, p.docs, p.api))
end

function remove_public!(idx::Index, uuid::AbstractString)
    for p in rows(idx, "SELECT id, status FROM packages WHERE uuid = ? AND status != 'local'", (uuid,))
        if p.status == "ok"
            package_fts!(idx, p.id; delete = true)
        end
        exec!(idx.db, """INSERT INTO defs_fts(defs_fts, rowid, name, words, signature, doc)
            SELECT 'delete', id, name, words, signature, doc FROM defs WHERE package = ?""", (p.id,))
        forget!(idx, [p.id])
    end
    exec!(idx.db, "DELETE FROM release_packages WHERE uuid = ?", (uuid,))
end

"""Apply a validated patch atomically, preserving local packages and their row ids."""
function apply_patch!(idx::Index, path::AbstractString; revision::Union{Nothing,AbstractString} = nothing)
    exec!(idx.db, "ATTACH DATABASE ? AS incoming", (abspath(joinpath(path, "romeo.sqlite")),))
    try
        SQLite.transaction(idx.db) do
            old = releaseinfo(idx)
            new = Dict(String(r.key) => String(r.value) for r in rows(idx, "SELECT * FROM incoming.index_release"))
            new["kind"] == "patch" || error("Expected a patch artifact")
            revision === nothing || new["revision"] == revision || error("Patch destination disagrees with release plan")
            old["revision"] == new["from"] || error("Patch requires $(new["from"]), installed index is $(old["revision"])")
            for key in ("schema", "model", "dimensions")
                old[key] == new[key] || error("Patch has incompatible $key")
            end
            for r in rows(idx, "SELECT uuid FROM incoming.removed UNION SELECT uuid FROM incoming.packages")
                remove_public!(idx, r.uuid)
            end
            for p in rows(idx, "SELECT id, uuid, status FROM incoming.packages ORDER BY id")
                columns = tablecolumns(idx, "packages"; omit = ("id",))
                exec!(idx.db, "INSERT INTO packages ($columns) SELECT $columns FROM incoming.packages WHERE id = ?", (p.id,))
                id = SQLite.last_insert_rowid(idx.db)
                for table in ("defs", "exports", "deps", "vectors", "problems")
                    columns = tablecolumns(idx, table; omit = ("id", "package"))
                    order = table == "defs" ? " ORDER BY id" : ""
                    exec!(idx.db, "INSERT INTO $table (package, $columns) SELECT ?, $columns FROM incoming.$table WHERE package = ?$order", (id, p.id))
                end
                columns = tablecolumns(idx, "function_vectors"; omit = ("definition", "package"))
                selected = join(("v." * c for c in split(columns, ", ")), ", ")
                exec!(idx.db, """INSERT INTO function_vectors(definition, package, $columns)
                    SELECT new.id, ?, $selected FROM incoming.function_vectors v
                    JOIN (SELECT id, row_number() OVER (ORDER BY id) AS n FROM incoming.defs WHERE package = ?) old ON old.id = v.definition
                    JOIN (SELECT id, row_number() OVER (ORDER BY id) AS n FROM main.defs WHERE package = ?) new ON new.n = old.n
                    WHERE v.package = ?""", (id, p.id, id, p.id))
                exec!(idx.db, "INSERT INTO defs_fts(rowid, name, words, signature, doc) SELECT id, name, words, signature, doc FROM defs WHERE package = ?", (id,))
                p.status == "ok" && package_fts!(idx, id)
            end
            exec!(idx.db, "INSERT OR REPLACE INTO release_packages SELECT * FROM incoming.release_packages")
            exec!(idx.db, "DELETE FROM downloads")
            exec!(idx.db, "INSERT INTO downloads SELECT * FROM incoming.downloads")
            releaseinfo!(idx, new)
        end
    finally
        exec!(idx.db, "DETACH DATABASE incoming")
    end
    return releaseinfo(idx)
end

"""Find a patch path without downloading anything, including across base refreshes."""
function patch_path(plan::AbstractDict, from::AbstractString)
    target = plan["target"]
    queue = [(String(from), Dict{String,Any}[])]
    seen = Set{String}()
    while !isempty(queue)
        revision, path = popfirst!(queue)
        revision == target && return path
        revision in seen && continue
        push!(seen, revision)
        for patch in get(plan, "patches", [])
            patch["from"] == revision || continue
            push!(queue, (String(patch["to"]), [path; patch]))
        end
    end
    error("No index patch path from $from to $target in this RomeoDB version")
end

struct IndexArtifactError{E} <: Exception
    name::String
    cause::E
end

function Base.showerror(io::IO, err::IndexArtifactError)
    print(io, "Could not install index artifact ", err.name, ": ")
    showerror(io, err.cause)
end

function release_asset(name::AbstractString, bindings::AbstractString)
    try
        return Artifacts.ensure_artifact_installed(String(name), String(bindings))
    catch err
        err isa InterruptException && rethrow()
        throw(IndexArtifactError(String(name), err))
    end
end

function index_plan(path::AbstractString)
    isfile(path) || error("This RomeoDB version has no published index release plan")
    plan = TOML.parsefile(path)
    plan["format"] == 1 || error("Unsupported index release plan format")
    return plan
end

"""
    ensure_index!(dir; plan = ..., bindings = ...)

Materialize the index state pinned by this package version. Downloads only missing
artifacts and applies only missing patches, under a process lock. No network polling
or background updater. Manually built indexes are left alone.
"""
function ensure_index!(dir::AbstractString;
                       plan::AbstractString = joinpath(@__DIR__, "..", "IndexRelease.toml"),
                       bindings::AbstractString = joinpath(@__DIR__, "..", "Artifacts.toml"))
    mkpath(dir)
    return Pidfile.mkpidlock(joinpath(abspath(dir), "index-release.pid"); stale_age = 600) do
        file = joinpath(dir, "romeo.sqlite")
        if isfile(file)
            idx = Index(dir)
            try
                info = releaseinfo(idx)
                if isempty(info)
                    count = only(rows(idx, "SELECT (SELECT count(*) FROM packages) + (SELECT count(*) FROM localroots) AS n")).n
                    count > 0 && return Dict("revision" => "unmanaged")
                else
                    release = index_plan(plan)
                    patches = patch_path(release, info["revision"])
                    # Download the entire missing chain before changing the index.
                    paths = try
                        [release_asset(p["artifact"], bindings) for p in patches]
                    catch err
                        err isa IndexArtifactError || rethrow()
                        @warn "RomeoDB: index download failed; using installed revision" revision = info["revision"] exception = (err, catch_backtrace())
                        return info
                    end
                    for (patch, path) in zip(patches, paths)
                        apply_patch!(idx, path; revision = patch["to"])
                    end
                    return releaseinfo(idx)
                end
            finally
                DBInterface.close!(idx.db)
            end
        end
        # Fresh installs choose the newest base with a route to the target.
        release = index_plan(plan)
        base = last(release["bases"])
        patches = patch_path(release, base["revision"])
        paths = [release_asset(p["artifact"], bindings) for p in [base; patches]]
        # Build alongside the destination, never at the final filename. A failed
        # download/apply leaves no partially installed database.
        mktempdir(dir) do stage
            cp(joinpath(first(paths), "romeo.sqlite"), joinpath(stage, "romeo.sqlite"))
            chmod(joinpath(stage, "romeo.sqlite"), 0o600)
            idx = Index(stage)
            try
                info = validate_release(idx)
                info["kind"] == "base" && info["revision"] == base["revision"] || error("Base disagrees with release plan")
                for (patch, path) in zip(patches, paths[2:end])
                    apply_patch!(idx, path; revision = patch["to"])
                end
                exec!(idx.db, "PRAGMA wal_checkpoint(TRUNCATE)")
            finally
                DBInterface.close!(idx.db)
            end
            if isfile(file)
                # An older chat may still have an empty database open. SQLite's
                # backup API updates that database safely; replacing its file
                # underneath live WAL connections would not.
                source = SQLite.DB(joinpath(stage, "romeo.sqlite"))
                try
                    SQLite.backup(source, file)
                finally
                    DBInterface.close!(source)
                end
            else
                mv(joinpath(stage, "romeo.sqlite"), file)
            end
        end
        return Dict("revision" => release["target"])
    end
end

"""Archive a release directory and bind a lazy artifact; upload is an explicit release step."""
function pack_release!(dir::AbstractString, name::AbstractString, archive::AbstractString,
                       bindings::AbstractString; url::AbstractString)
    isfile(joinpath(dir, "romeo.sqlite")) || error("Missing release database")
    wal = joinpath(dir, "romeo.sqlite-wal")
    isfile(wal) && filesize(wal) > 0 && error("Checkpoint and close the release database before archiving")
    hash = Artifacts.create_artifact() do root
        cp(joinpath(dir, "romeo.sqlite"), joinpath(root, "romeo.sqlite"))
    end
    if isfile(bindings)
        bound = Artifacts.artifact_hash(String(name), String(bindings))
        bound === nothing || bound == hash || error("Artifact $name already names different content; use a new release revision")
    end
    mkpath(dirname(abspath(archive)))
    sha = Artifacts.archive_artifact(hash, archive)
    Artifacts.bind_artifact!(bindings, String(name), hash; download_info = [(String(url), sha)], lazy = true, force = true)
    return (; hash, sha256 = sha, bytes = filesize(archive))
end
