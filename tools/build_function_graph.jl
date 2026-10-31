using RomeoDB

"""
Build/resume public function vectors, then construct the ecosystem neighbour
graph once. Checkpointed vectors survive an interrupted run. Output is a compact
graph and cluster manifest for the GUI, independent of a running GPU model.
"""
function build_function_graph(idx, embedder, output;
                              dimensions = 256, limit = typemax(Int), k = 10,
                              minsimilarity = 0.75, cluster_similarity = 0.8, mintokens = 40,
                              embedding_progress = (done, total) -> nothing,
                              index_progress = n -> nothing,
                              graph_progress = (done, total) -> nothing)
    model = RomeoDB.functionmodel(embedder)
    count = RomeoDB.embed_functions!(idx, embedder; dimensions, model, limit,
                                    public_only = true, mintokens, progress = embedding_progress)
    coverage = RomeoDB.function_coverage(idx; model, dimensions, mintokens, public_only = true)
    index = RomeoDB.functionindex(idx; model, dimensions, approximate = true,
                                  public_only = true, progress = index_progress)
    graph = RomeoDB.semantic_graph(index; k, minsimilarity, progress = graph_progress)
    groups = RomeoDB.semantic_clusters(idx, index; graph, minsimilarity = cluster_similarity, limit = typemax(Int))
    RomeoDB.write_function_graph(output, graph)
    manifest = Dict("eligible_functions" => coverage.eligible, "embedded_functions" => coverage.embedded,
        "new_vectors" => count, "k" => k, "edge_threshold" => minsimilarity, "minimum_tokens" => mintokens,
        "cluster_threshold" => cluster_similarity, "groups" => [Dict(
            "representative" => g.representative.id,
            "members" => [h.id for h in g.members], "packages" => g.packages,
            "minimum_similarity" => g.minimum_similarity) for g in groups])
    open(io -> RomeoDB.TOML.print(io, manifest), joinpath(output, "clusters.toml"), "w")
    return (; coverage, graph_nodes = length(graph.ids), graph_edges = length(graph.edges),
        clusters = length(groups), output)
end
