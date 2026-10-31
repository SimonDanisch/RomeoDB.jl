# SPDX-FileCopyrightText: 2026 Simon Danisch
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Pinned software sources for the optional Qwen runner; model weights stay lazy artifacts."""
function embedding_runtime_specs(path::AbstractString = joinpath(@__DIR__, "..", "EmbeddingRuntime.toml"))
    sources = TOML.parsefile(path)["sources"]
    return [Pkg.PackageSpec(; name, url = spec["url"], rev = spec["rev"],
        subdir = get(spec, "subdir", nothing)) for (name, spec) in sort!(collect(sources); by = first)]
end

"""
    install_embedding_runtime!()

Install the optional runner and its pinned GPU-stack sources into the active Julia
project using Pkg. No model weights are downloaded. Call during worker provisioning,
before launching the MCP process, or explicitly in the environment using RomeoDB.
"""
function install_embedding_runtime!()
    specs = embedding_runtime_specs()
    installed = Dict(p.name => p for p in values(Pkg.dependencies()))
    current = all(specs) do spec
        package = get(installed, spec.name, nothing)
        package !== nothing && (package.is_tracking_path ||
            (package.git_source == spec.url && package.git_revision == spec.rev))
    end
    current && return nothing
    @info "RomeoDB: installing optional Qwen embedding software (model data remains lazy)"
    Pkg.add(specs)
    return nothing
end
