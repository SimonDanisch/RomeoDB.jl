# SPDX-FileCopyrightText: 2026 Simon Danisch
# SPDX-License-Identifier: AGPL-3.0-or-later

# Real-model pilot on public ecosystem implementations. This measures retrieval
# in an explicitly bounded corpus, not recall over the whole registry.
using RomeoDB

function evaluate_function_semantics(idx, embedder; per_name = 6, dimensions = 256,
                                      output = nothing, progress = (done, total) -> nothing)
    names = ["meshgrid", "ndgrid", "sumsq", "sumabs2", "sqnorm", "squarednorm", "norm2",
             "mean", "var", "std", "median", "logsumexp", "softmax", "sigmoid", "normalize",
             "clamp", "cumsum", "cumprod", "dot", "levenshtein", "editdistance", "argmin", "argmax"]
    selected = RomeoDB.rows(idx, """SELECT id FROM (
        SELECT d.id, row_number() OVER (PARTITION BY d.basename ORDER BY (d.nlines BETWEEN 3 AND 30) DESC, (length(d.doc)>0) DESC, d.ntokens, d.id) AS rank
        FROM defs d JOIN packages p ON p.id=d.package
        WHERE p.status='ok' AND d.kind='function' AND d.generated=0 AND d.ntokens>=16
          AND d.nlines BETWEEN 1 AND 80 AND d.basename IN ($(join(fill("?", length(names)), ", "))))
        WHERE rank<=? ORDER BY id""", (names..., per_name))
    ids = Int[r.id for r in selected]
    isempty(ids) && error("Pilot corpus is empty")
    started = time()
    embedded = RomeoDB.embed_functions!(idx, embedder; ids, dimensions, mintokens = 16, progress)
    index = RomeoDB.functionindex(idx; model = RomeoDB.functionmodel(embedder), dimensions)
    # Keep this evaluation's search corpus fixed, even if other function vectors
    # have already been built by a different pilot.
    positions = findall(id -> id in ids, index.ids)
    subset = RomeoDB.FunctionIndex(index.ids[positions], index.packages[positions], index.vectors[:, positions], index.model, index.recipe, nothing)
    queries = [
        (label = "sum of squares", relevant = Set(["sumsq", "sumabs2", "sqnorm", "squarednorm", "norm2"]),
         code = "function helper_a(xs)\n acc=0.0\n for item in xs\n acc += item*item\n end\n return acc\nend"),
        (label = "coordinate grid", relevant = Set(["meshgrid", "ndgrid"]),
         code = "function helper_b(xs, ys)\n xx=[xs[j] for i in eachindex(ys), j in eachindex(xs)]\n yy=[ys[i] for i in eachindex(ys), j in eachindex(xs)]\n return xx, yy\nend"),
        (label = "arithmetic mean", relevant = Set(["mean"]),
         code = "function helper_c(xs)\n total=0.0\n count=0\n for item in xs\n total+=item\n count+=1\n end\n return total/count\nend"),
        (label = "stable log sum exp", relevant = Set(["logsumexp"]),
         code = "function helper_d(xs)\n shift=maximum(xs)\n acc=0.0\n for item in xs\n acc+=exp(item-shift)\n end\n return shift+log(acc)\nend")]
    results = map(queries) do query
        hits = only(RomeoDB.semantic_similar(idx, subset, embedder, query.code; limit = 5, minsimilarity = -1)).hits
        rank = findfirst(h -> RomeoDB.shortname(h.definition.name) in query.relevant, hits)
        (; query = query.label, rank, hits = [(package = h.definition.package, name = h.definition.name,
             id = h.definition.id, cosine = h.similarity) for h in hits])
    end
    graph = RomeoDB.semantic_graph(subset; k = 8, minsimilarity = 0.8)
    clusters = RomeoDB.semantic_clusters(idx, subset; graph, minsimilarity = 0.8, limit = 20)
    report = (; model = subset.model, dimensions, corpus_functions = length(subset.ids),
        corpus_packages = length(unique(subset.packages)), newly_embedded = embedded, seconds = time() - started,
        mrr_at_5 = sum(r.rank === nothing ? 0.0 : 1 / r.rank for r in results) / length(results),
        queries = results, clusters = [(representative = c.representative.name,
            packages = c.packages, minimum_similarity = c.minimum_similarity,
            structural_variants = only(RomeoDB.rows(idx, "SELECT count(DISTINCT renamed) AS n FROM defs WHERE id IN ($(join([h.id for h in c.members], ", ")))")).n,
            members = [(id = h.id, package = h.package, name = h.name) for h in c.members]) for c in clusters])
    if output !== nothing
        mkpath(dirname(abspath(output)))
        write(output, RomeoDB.JSON3.write(report))
    end
    return report
end
