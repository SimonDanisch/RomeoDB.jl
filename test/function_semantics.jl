# SPDX-FileCopyrightText: 2026 Simon Danisch
# SPDX-License-Identifier: AGPL-3.0-or-later

# These deterministic vectors test indexing/search/graph contracts. Real-model
# retrieval quality is evaluated separately; this fixture is not that evidence.
mutable struct FunctionFixtureEmbedder
    calls::Vector{String}
end
RomeoDB.functionmodel(::FunctionFixtureEmbedder) = "function-fixture-v1"
RomeoDB.embeddocument(m::FunctionFixtureEmbedder, text::AbstractString) = RomeoDB.embedfunction(m, text)
RomeoDB.embedquery(m::FunctionFixtureEmbedder, text::AbstractString) = RomeoDB.embedfunction(m, text)
function RomeoDB.embedfunction(m::FunctionFixtureEmbedder, text::AbstractString)
    push!(m.calls, String(text))
    low = lowercase(text)
    occursin("coordinate", low) && return Float32[1, 0, 0, 0]
    occursin("squared", low) && return Float32[0, 1, 0, 0]
    return Float32[0, 0, 1, 0]
end

@testset "function-level semantic indexing and clustering" begin
    mktempdir() do root
        idx = RomeoDB.Index(joinpath(root, "data"))
        model = FunctionFixtureEmbedder(String[])
        function add(name, uuid, doc, body)
            path = joinpath(root, name)
            mkpath(joinpath(path, "src"))
            write(joinpath(path, "src", "$name.jl"), "module $name\n\"\"\"$doc\"\"\"\n$body\nend")
            p = RomeoDB.PackageVersion(Base.UUID(uuid), name, v"1.0.0", Base.SHA1(fill(UInt8(uuid), 20)), "https://example.test/$name")
            RomeoDB.store!(idx, p, "ok", RomeoDB.extract(path, name))
            mkpath(dirname(RomeoDB.sourcedir(idx, p)))
            cp(path, RomeoDB.sourcedir(idx, p); force = true)
        end
        try
            add("BroadcastGrid", 1, "Coordinate matrices for every pair of coordinates.",
                "mesh(xs, ys) = (repeat(reshape(xs, 1, :), length(ys), 1), repeat(ys, 1, length(xs)))")
            add("LoopGrid", 2, "Coordinate matrices for every pair of coordinates.",
                "function lattice(a, b)\n x = [a[j] for i in eachindex(b), j in eachindex(a)]\n y = [b[i] for i in eachindex(b), j in eachindex(a)]\n return x, y\nend")
            add("NormTools", 3, "Sum of squared entries in a vector.",
                "function energy(xs)\n total=zero(eltype(xs))\n for x in xs\n total += x*x\n end\n return total\nend")
            RomeoDB.reindex_text!(idx)
            @test_throws ErrorException RomeoDB.functionindex(idx)
            @test RomeoDB.embed_functions!(idx, model; dimensions = 4, mintokens = 0) == 3
            @test length(model.calls) == 3
            @test any(t -> occursin("return x, y", t), model.calls)
            @test !any(t -> occursin("BroadcastGrid", t), model.calls) # no owning-package signal
            @test RomeoDB.embed_functions!(idx, model; dimensions = 4, mintokens = 0) == 0
            @test RomeoDB.function_coverage(idx; model = RomeoDB.functionmodel(model), dimensions = 4, mintokens = 0).missing == 0
            @test all(r -> r.bytes == 8, RomeoDB.rows(idx, "SELECT length(vec) AS bytes FROM function_vectors"))
            index = RomeoDB.functionindex(idx)
            loop = only(RomeoDB.definition(idx, "LoopGrid", "lattice"))
            near = RomeoDB.semantic_neighbors(idx, index, loop.id; cross_packages = true, minsimilarity = 0.9)
            @test only(near).definition.package == "BroadcastGrid"
            @test only(near).similarity ≈ 1
            loads = Ref(0)
            lazy = RomeoDB.Server(idx; loader = () -> begin
                loads[] += 1
                () -> model
            end)
            for method in ("initialize", "tools/list", "ping")
                message = RomeoDB.JSON3.read(RomeoDB.JSON3.write(Dict("jsonrpc" => "2.0", "id" => 1, "method" => method)))
                @test haskey(RomeoDB.handle(lazy, message), "result")
            end
            @test loads[] == 0
            RomeoDB.semantic!(lazy)
            lazyworker = @atomic lazy.embedder
            @test timedwait(() -> RomeoDB.ready(lazyworker), 10) === :ok
            @test loads[] == 1
            @test RomeoDB.functionsemantic!(lazy) !== nothing
            @test loads[] == 1
            close(lazyworker.requests)
            wait(lazyworker.task)

            # Discovery on an empty worker neither provisions the index nor
            # starts the model, even with both enabled.
            discovery = join([RomeoDB.JSON3.write(Dict("jsonrpc" => "2.0", "id" => i,
                "method" => method)) for (i, method) in enumerate(("initialize", "tools/list", "ping"))], "\n") * "\n"
            output = IOBuffer()
            RomeoDB.serve(joinpath(root, "empty-server"); input = IOBuffer(discovery), output,
                provision = true, embedder = () -> error("Discovery must not load a model"))
            @test length(split(strip(String(take!(output))), '\n')) == 3
            @test isempty(readdir(joinpath(root, "empty-server", "sources")))
            code = "function different_name(xx, yy)\n return [x for y in yy, x in xx], [y for y in yy, x in xx]\nend"
            matches = RomeoDB.semantic_similar(idx, index, model, code; purpose = "Coordinate matrices", minsimilarity = 0.9, exclude = ["LoopGrid"])
            @test only(only(matches).hits).definition.package == "BroadcastGrid"
            result = RomeoDB.find_existing(idx, RomeoDB.sketches(idx), code, "Coordinate matrices";
                function_semantic = RomeoDB.FunctionSemantic(model, index), exclude = ["LoopGrid"])
            @test first(only(result.semantic_functions).hits).definition.package == "BroadcastGrid"
            @test RomeoDB.find_existing(idx, RomeoDB.sketches(idx), code, "Coordinate matrices").semantic_functions === nothing
            worker = RomeoDB.EmbedWorker(() -> model)
            try
                @test timedwait(() -> RomeoDB.ready(worker), 10) === :ok
                server = RomeoDB.Server(idx, worker)
                @test RomeoDB.functionsemantic!(server).index.model == "function-fixture-v1"
                message = RomeoDB.JSON3.read(RomeoDB.JSON3.write(Dict("jsonrpc" => "2.0", "id" => 1,
                    "method" => "tools/call", "params" => Dict("name" => "similar_functionality",
                        "arguments" => Dict("code" => code, "purpose" => "Coordinate matrices", "exclude_packages" => ["LoopGrid"])))))
                response = RomeoDB.handle(server, message)
                @test !response["result"]["isError"]
                @test occursin("BroadcastGrid", only(response["result"]["content"])["text"])
            finally
                close(worker.requests)
                wait(worker.task)
            end

            approximate = RomeoDB.functionindex(idx; approximate = true)
            @test only(RomeoDB.semantic_neighbors(idx, approximate, loop.id; cross_packages = true, minsimilarity = 0.9)).definition.package == "BroadcastGrid"
            graph = RomeoDB.semantic_graph(approximate; k = 2, minsimilarity = 0.9)
            @test length(graph.edges) == 1
            RomeoDB.write_function_graph(joinpath(root, "graph"), graph)
            loaded_graph = RomeoDB.read_function_graph(joinpath(root, "graph"))
            @test loaded_graph.ids == graph.ids
            @test [(e.source,e.target,e.similarity) for e in loaded_graph.edges] == [(e.source,e.target,e.similarity) for e in graph.edges]
            clusters = RomeoDB.semantic_clusters(idx, approximate; graph, minsimilarity = 0.9)
            @test only(clusters).packages == ["BroadcastGrid", "LoopGrid"]

            # A lazy graph artifact must also work when patching has assigned
            # different SQLite ids on the receiving worker.
            open(joinpath(root, "graph", "clusters.toml"), "w") do io
                RomeoDB.TOML.print(io, Dict("groups" => [Dict(
                    "representative" => c.representative.id, "members" => [h.id for h in c.members],
                    "packages" => c.packages, "minimum_similarity" => c.minimum_similarity) for c in clusters]))
            end
            RomeoDB.releaseinfo!(idx, Dict("schema" => "1", "revision" => "graph1", "registry" => "fixture",
                "model" => "none", "dimensions" => "0", "kind" => "base"))
            staged = RomeoDB.stage_graph_release!(idx, joinpath(root, "graph"), joinpath(root, "graph-release"); revision = "graph1")
            bindings = joinpath(root, "GraphArtifacts.toml")
            archive = joinpath(root, "graph.tar.gz")
            packed = RomeoDB.pack_graph_release!(staged, "ecosystem-graph1", archive, bindings; url = "file://" * archive)
            @test RomeoDB.TOML.parsefile(bindings)["ecosystem-graph1"]["lazy"]
            plan = joinpath(root, "GraphRelease.toml")
            open(io -> RomeoDB.TOML.print(io, Dict("format" => 1, "target" => "graph1",
                "graph" => Dict("revision" => "graph1", "artifact" => "ecosystem-graph1"))), plan, "w")
            RomeoDB.exec!(idx.db, "UPDATE defs SET id=id+10000")
            RomeoDB.exec!(idx.db, "UPDATE function_vectors SET definition=definition+10000")
            withenv("JULIA_PKG_SERVER" => "") do
                Pkg.Artifacts.with_artifacts_directory(joinpath(root, "graph-artifact-store")) do
                    @test !Pkg.Artifacts.artifact_exists(packed.hash)
                    resolved = RomeoDB.ecosystem_data(idx; plan, bindings)
                    @test Pkg.Artifacts.artifact_exists(packed.hash)
                    @test resolved.graph.ids == graph.ids .+ 10000
                    @test only(resolved.groups)["members"] == [h.id + 10000 for h in only(clusters).members]
                end
            end
            RomeoDB.exec!(idx.db, "UPDATE defs SET id=id-10000")
            RomeoDB.exec!(idx.db, "UPDATE function_vectors SET definition=definition-10000")

            # A-B and B-C qualify, A-C does not. Complete-link clustering must
            # not turn the whole connected component into a duplicate group.
            vectors = Float32[1 cospi(1/6) cospi(1/3); 0 sinpi(1/6) sinpi(1/3)]
            chain = RomeoDB.FunctionIndex(index.ids, index.packages, vectors, index.model, index.recipe, nothing)
            chain_graph = RomeoDB.semantic_graph(chain; k = 2, minsimilarity = 0.8)
            chain_clusters = RomeoDB.semantic_clusters(idx, chain; graph = chain_graph, minsimilarity = 0.8)
            @test length(only(chain_clusters).members) == 2
            @test only(chain_clusters).minimum_similarity >= 0.8

            # Same text elsewhere reuses its vector without another model call.
            add("AnotherGrid", 4, "Coordinate matrices for every pair of coordinates.",
                "mesh(xs, ys) = (repeat(reshape(xs, 1, :), length(ys), 1), repeat(ys, 1, length(xs)))")
            calls = length(model.calls)
            @test RomeoDB.embed_functions!(idx, model; dimensions = 4, mintokens = 0) == 1
            @test length(model.calls) == calls

            # Snapshot and patch ids differ once local records occupy ids in
            # the target. Function vectors must still refer to the right defs.
            RomeoDB.reindex_text!(idx)
            RomeoDB.release_snapshot!(idx, joinpath(root, "s0"); revision = "s0", registry = "r0")
            before = RomeoDB.Index(joinpath(root, "s0"))
            try
                @test only(RomeoDB.rows(before, "SELECT count(*) AS n FROM function_vectors")).n == 4
                add("MoreNorms", 5, "Sum of squared entries in a vector.", "energy2(xs) = sum(abs2, xs)")
                RomeoDB.embed_functions!(idx, model; dimensions = 4, mintokens = 0)
                RomeoDB.reindex_text!(idx)
                RomeoDB.release_snapshot!(idx, joinpath(root, "s1"); revision = "s1", registry = "r1")
                after = RomeoDB.Index(joinpath(root, "s1"))
                try
                    RomeoDB.release_patch!(before, after, joinpath(root, "patch"))
                finally
                    RomeoDB.DBInterface.close!(after.db)
                end
                localpath = joinpath(root, "LocalPkg")
                mkpath(joinpath(localpath, "src"))
                write(joinpath(localpath, "Project.toml"), "name=\"LocalPkg\"\nuuid=\"$(Base.UUID(99))\"\n")
                write(joinpath(localpath, "src", "LocalPkg.jl"), "module LocalPkg\nprivate_fn(x)=x+1\nend")
                RomeoDB.addlocal!(before, localpath)
                @test RomeoDB.embed_functions!(before, model; dimensions = 4, mintokens = 0) == 1
                RomeoDB.apply_patch!(before, joinpath(root, "patch"))
                @test only(RomeoDB.rows(before, "SELECT count(*) AS n FROM function_vectors v JOIN defs d ON d.id=v.definition WHERE v.package=d.package")).n == 6
                @test only(RomeoDB.rows(before, "SELECT count(*) AS n FROM function_vectors v JOIN packages p ON p.id=v.package WHERE p.status='local'")).n == 1
                @test length(RomeoDB.functionindex(before; public_only = true).ids) == 5
                @test RomeoDB.function_coverage(before; model = RomeoDB.functionmodel(model), dimensions = 4,
                    mintokens = 0, public_only = true).embedded == 5
                moved = only(RomeoDB.definition(before, "MoreNorms", "energy2"))
                @test only(RomeoDB.rows(before, "SELECT d.name FROM function_vectors v JOIN defs d ON d.id=v.definition WHERE v.definition=?", (moved.id,))).name == "energy2"
                RomeoDB.release_snapshot!(before, joinpath(root, "public"); revision = "public", registry = "r1")
                public = RomeoDB.Index(joinpath(root, "public"))
                try
                    @test only(RomeoDB.rows(public, "SELECT count(*) AS n FROM function_vectors")).n == 5
                finally
                    RomeoDB.DBInterface.close!(public.db)
                end
            finally
                RomeoDB.DBInterface.close!(before.db)
            end
            removed = only(RomeoDB.rows(idx, "SELECT id FROM packages WHERE name='NormTools'")).id
            RomeoDB.forget!(idx, [removed])
            @test isempty(RomeoDB.rows(idx, "SELECT * FROM function_vectors WHERE package=?", (removed,)))
            @test_throws ArgumentError RomeoDB.compact_function_vector(Float32[NaN], 1)
        finally
            RomeoDB.DBInterface.close!(idx.db)
        end
    end
end
