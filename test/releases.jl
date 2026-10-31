# SPDX-FileCopyrightText: 2026 Simon Danisch
# SPDX-License-Identifier: AGPL-3.0-or-later

include(joinpath(@__DIR__, "..", "tools", "build_release.jl"))

@testset "version-pinned index artifacts" begin
    import Pkg.Artifacts
    mktempdir() do root
        function package!(idx, name, uuid, tree, body; text = "A useful public package for coordinate matrices")
            path = joinpath(root, "sources", name, tree)
            mkpath(joinpath(path, "src"))
            write(joinpath(path, "src", "$name.jl"), "module $name\n\"\"\"$text\"\"\"\n$body\nend\n")
            p = RomeoDB.PackageVersion(Base.UUID(uuid), name, v"1.0.0", Base.SHA1(repeat(tree, 40)), "https://example.test/$name.jl")
            RomeoDB.store!(idx, p, "ok", RomeoDB.extract(path, name))
        end
        old = RomeoDB.Index(joinpath(root, "old"))
        new = RomeoDB.Index(joinpath(root, "new"))
        handles = [old, new]
        try
            package!(old, "Alpha", 101, "a", "oldgrid(x) = x + 1")
            package!(old, "Removed", 102, "b", "removedgrid(x) = x - 1")
            package!(old, "Stable", 103, "c", "stablegrid(x) = x * 2")
            package!(new, "Alpha", 101, "d", "newgrid(x) = x + 2"; text = "A changed public package for ocean simulation")
            package!(new, "Added", 104, "e", "addedgrid(x) = x / 2")
            package!(new, "Stable", 103, "c", "stablegrid(x) = x * 2")
            for idx in (old, new)
                private = joinpath(root, "Private")
                mkpath(joinpath(private, "src"))
                write(joinpath(private, "Project.toml"), "name = \"Private\"\nuuid = \"00000000-0000-0000-0000-000000000099\"\n")
                write(joinpath(private, "src", "Private.jl"), "module Private\nsecretgrid(x) = x\nend")
                RomeoDB.addlocal!(idx, private)
                RomeoDB.embed_packages!(idx, ToyEmbedder())
            end
            RomeoDB.exec!(new.db, "INSERT INTO downloads VALUES (?, 42, 84)", (string(Base.UUID(101)),))
            for (idx, revision) in ((old, "r0"), (new, "r1"))
                RomeoDB.release_snapshot!(idx, joinpath(root, revision); revision, registry = "registry-$revision", model = "toy-v1", dimensions = 8)
            end
            before, after = RomeoDB.Index(joinpath(root, "r0")), RomeoDB.Index(joinpath(root, "r1"))
            append!(handles, [before, after])
            @test RomeoDB.validate_release(before)["revision"] == "r0"
            @test isempty(RomeoDB.rows(before, "SELECT * FROM localroots"))
            @test isempty(RomeoDB.rows(before, "SELECT * FROM packages WHERE name = 'Private'"))
            result = RomeoDB.release_patch!(before, after, joinpath(root, "p01"))
            @test result.changed == 2
            @test result.removed == 1
            patch = RomeoDB.Index(result.path)
            push!(handles, patch)
            @test Set(r.name for r in RomeoDB.rows(patch, "SELECT name FROM packages")) == Set(["Alpha", "Added"])
            @test isempty(RomeoDB.rows(patch, "SELECT * FROM localroots"))

            bindings = joinpath(root, "Artifacts.toml")
            for (path, name) in ((before.dir, "base0"), (after.dir, "base1"), (patch.dir, "patch01"))
                archive = joinpath(root, "$name.tar.gz")
                RomeoDB.pack_release!(path, name, archive, bindings; url = "file://" * archive)
            end
            plan = joinpath(root, "IndexRelease.toml")
            release = Dict("format" => 1, "target" => "r0", "bases" => [Dict("revision" => "r0", "artifact" => "base0")],
                           "patches" => Any[])
            writeplan() = open(io -> RomeoDB.TOML.print(io, release), plan, "w")
            writeplan()
            withenv("JULIA_PKG_SERVER" => "") do
              Pkg.Artifacts.with_artifacts_directory(joinpath(root, "artifact-store")) do
                installed = joinpath(root, "installed")
                @test RomeoDB.ensure_index!(installed; plan, bindings)["revision"] == "r0"
                @test RomeoDB.ensure_index!(installed; plan, bindings)["revision"] == "r0"
                current = RomeoDB.Index(installed)
                private = joinpath(root, "Private")
                RomeoDB.addlocal!(current, private)
                privateid = only(RomeoDB.rows(current, "SELECT id FROM packages WHERE name = 'Private'")).id
                DBInterface = RomeoDB.DBInterface
                DBInterface.close!(current.db)
                release["target"] = "r1"
                push!(release["patches"], Dict("from" => "r0", "to" => "r1", "artifact" => "patch01"))
                # A newer base is available, but an existing r0 installation
                # must take the patch and never try to download this base.
                push!(release["bases"], Dict("revision" => "r1", "artifact" => "not-published"))
                writeplan()
                @test RomeoDB.ensure_index!(installed; plan, bindings)["revision"] == "r1"
                release["target"] = "r2"
                push!(release["patches"], Dict("from" => "r1", "to" => "r2", "artifact" => "missing-patch"))
                writeplan()
                @test_logs (:warn, r"index download failed; using installed revision") begin
                    @test RomeoDB.ensure_index!(installed; plan, bindings)["revision"] == "r1"
                end
                pop!(release["patches"])
                release["target"] = "r1"
                writeplan()
                current = RomeoDB.Index(installed)
                push!(handles, current)
                @test only(RomeoDB.rows(current, "SELECT id FROM packages WHERE name = 'Private'")).id == privateid
                @test Set(r.name for r in RomeoDB.rows(current, "SELECT name FROM packages")) == Set(["Alpha", "Added", "Stable", "Private"])
                @test only(RomeoDB.rows(current, "SELECT users FROM downloads WHERE uuid = ?", (string(Base.UUID(101)),))).users == 42
                @test isempty(RomeoDB.rows(current, "SELECT * FROM defs_fts WHERE defs_fts MATCH 'oldgrid OR removedgrid'"))
                @test !isempty(RomeoDB.rows(current, "SELECT rowid FROM defs_fts WHERE defs_fts MATCH 'newgrid'"))
                @test Set(r.name for r in RomeoDB.packages(current, "ocean simulation")) == Set(["Alpha"])
                @test RomeoDB.ensure_index!(installed; plan, bindings)["revision"] == "r1"
                # Source inspection works without shipping the source cache.
                server = joinpath(root, "package-server")
                archive = joinpath(server, "package", string(Base.UUID(101)), repeat("d", 40))
                mkpath(dirname(archive))
                open(archive, "w") do io
                    gz = RomeoDB.CodecZlib.GzipCompressorStream(io)
                    RomeoDB.Tar.create(joinpath(root, "sources", "Alpha", "d"), gz)
                    close(gz)
                end
                lazy = RomeoDB.Index(installed; server = "file://" * server)
                push!(handles, lazy)
                hit = only(RomeoDB.definition(lazy, "Alpha", "newgrid"))
                @test occursin("newgrid", RomeoDB.source(lazy, hit))
                rm(archive)
                @test occursin("newgrid", RomeoDB.source(lazy, hit))
                @test_throws ErrorException RomeoDB.apply_patch!(current, patch.dir)

                # A fresh installation uses the new base instead of replaying
                # historical patches, and a missing artifact leaves no index.
                @test_throws Exception RomeoDB.ensure_index!(joinpath(root, "failed"); plan, bindings)
                @test !isfile(joinpath(root, "failed", "romeo.sqlite"))
                release["bases"][end]["artifact"] = "base1"
                writeplan()
                @test RomeoDB.ensure_index!(joinpath(root, "fresh"); plan, bindings)["revision"] == "r1"
                empty = RomeoDB.Index(joinpath(root, "already-open"))
                push!(handles, empty)
                @test RomeoDB.ensure_index!(empty.dir; plan, bindings)["revision"] == "r1"
                @test RomeoDB.releaseinfo(empty)["revision"] == "r1"
                @test !isempty(RomeoDB.rows(empty, "SELECT id FROM packages WHERE name = 'Alpha'"))
                # Pkg downgrade / missing upgrade routes fail without changing
                # a working database or downloading a replacement base.
                release["target"] = "r0"
                writeplan()
                @test_throws ErrorException RomeoDB.ensure_index!(installed; plan, bindings)
                @test RomeoDB.releaseinfo(current)["revision"] == "r1"
              end
            end

            # Roll back records, FTS, vectors and revision together if a patch
            # fails after deletions have already happened.
            target = RomeoDB.Index(joinpath(root, "rollback"))
            push!(handles, target)
            RomeoDB.DBInterface.close!(target.db)
            cp(joinpath(before.dir, "romeo.sqlite"), joinpath(target.dir, "romeo.sqlite"); force = true)
            target = RomeoDB.Index(target.dir)
            push!(handles, target)
            RomeoDB.exec!(target.db, "CREATE TRIGGER fail_patch BEFORE INSERT ON packages WHEN NEW.name = 'Added' BEGIN SELECT RAISE(ABORT, 'injected patch failure'); END")
            @test_throws ErrorException RomeoDB.apply_patch!(target, patch.dir; revision = "wrong-target")
            @test_throws Exception RomeoDB.apply_patch!(target, patch.dir)
            @test RomeoDB.releaseinfo(target)["revision"] == "r0"
            @test !isempty(RomeoDB.rows(target, "SELECT rowid FROM defs_fts WHERE defs_fts MATCH 'oldgrid'"))
            @test isempty(RomeoDB.rows(target, "SELECT rowid FROM defs_fts WHERE defs_fts MATCH 'newgrid'"))
            @test only(RomeoDB.rows(target, "SELECT count(*) AS n FROM vectors")).n == 3

            # Changes to records under the SAME source tree must also enter a
            # patch (e.g. an improved extractor or corrected summary).
            RomeoDB.exec!(new.db, "UPDATE packages SET summary = 'Corrected summary' WHERE name = 'Stable'")
            RomeoDB.release_snapshot!(new, joinpath(root, "r2"); revision = "r2", registry = "registry-r2", model = "toy-v1", dimensions = 8)
            next = RomeoDB.Index(joinpath(root, "r2"))
            push!(handles, next)
            @test RomeoDB.release_patch!(after, next, joinpath(root, "p12")).changed == 1
            @test_throws ErrorException RomeoDB.release_patch!(after, after, joinpath(root, "invalid"))
            # An unmanaged local database never requires a release plan and is
            # not silently replaced by the shipped registry snapshot.
            @test RomeoDB.ensure_index!(old.dir; plan = joinpath(root, "absent"), bindings)["revision"] == "unmanaged"

            # Exercise the release-preparation entry point without downloading
            # General or requiring a GPU. These are prebuilt public fixtures;
            # update! must reuse them and stage only a delta for week two.
            builder = RomeoDB.Index(joinpath(root, "builder"))
            package!(builder, "BuildPkg", 201, "f", "buildgrid(x) = x + 1")
            RomeoDB.DBInterface.close!(builder.db)
            versions = [RomeoDB.PackageVersion(Base.UUID(201), "BuildPkg", v"1.0.0", Base.SHA1(repeat("f", 40)), "https://example.test/BuildPkg.jl")]
            first = build_index_release(builder.dir, joinpath(root, "week1"); revision = "week1", registry = "registry1",
                url_prefix = "https://example.test/releases/week1", versions, stats = false,
                embedder = ToyEmbedder(), model = "toy-v1", dimensions = 8,
                previous_plan = joinpath(root, "absent-plan.toml"),
                previous_bindings = joinpath(root, "absent-artifacts.toml"))
            @test length(first.archives) == 1
            @test occursin("base", only(first.archives).name)
            builder = RomeoDB.Index(builder.dir)
            package!(builder, "BuildPkg", 201, "1", "buildgrid(x) = x + 2")
            RomeoDB.DBInterface.close!(builder.db)
            versions = [RomeoDB.PackageVersion(Base.UUID(201), "BuildPkg", v"1.0.0", Base.SHA1(repeat("1", 40)), "https://example.test/BuildPkg.jl")]
            second = build_index_release(builder.dir, joinpath(root, "week2"); revision = "week2", registry = "registry2",
                url_prefix = "https://example.test/releases/week2", versions, stats = false,
                embedder = ToyEmbedder(), model = "toy-v1", dimensions = 8,
                previous = first.snapshot, previous_plan = first.plan, previous_bindings = first.bindings)
            @test length(second.archives) == 1
            @test only(second.archives).changed == 1
            plan2 = RomeoDB.TOML.parsefile(second.plan)
            @test plan2["target"] == "week2"
            @test length(plan2["bases"]) == 1
            @test only(RomeoDB.patch_path(plan2, "week1"))["to"] == "week2"
            @test length(RomeoDB.TOML.parsefile(second.bindings)) == 2
            third = build_index_release(builder.dir, joinpath(root, "week3"); revision = "week3", registry = "registry3",
                url_prefix = "https://example.test/releases/week3", versions, stats = false, new_base = true,
                embedder = ToyEmbedder(), model = "toy-v1", dimensions = 8,
                previous = second.snapshot, previous_plan = second.plan, previous_bindings = second.bindings)
            @test length(third.archives) == 2
            plan3 = RomeoDB.TOML.parsefile(third.plan)
            @test length(RomeoDB.patch_path(plan3, "week1")) == 2
            @test isempty(RomeoDB.patch_path(plan3, last(plan3["bases"])["revision"]))
        finally
            for idx in handles
                RomeoDB.DBInterface.close!(idx.db)
            end
        end
    end
end
