# SPDX-FileCopyrightText: 2026 Simon Danisch
# SPDX-License-Identifier: AGPL-3.0-or-later

"""
A queryable index of the Julia ecosystem: every function, macro and type in the General
registry, with its docstring, signature, size and a canonical form for finding clones
across packages.
"""
module RomeoDB

using Base: UUID, SHA1
import CodecZlib
import DBInterface
import Downloads
import JSON3
import JuliaSyntax
using JuliaSyntax: SyntaxNode, @K_str, kind, children, numchildren, sourcetext
import PrecompileTools
import RegistryInstances
import SHA
import SQLite
import Tar
import TOML
import Pkg
import Pkg.Artifacts
import FileWatching.Pidfile
import HNSW
using LinearAlgebra: normalize!, dot

include("canonical.jl")
include("extract.jl")
include("registry.jl")
include("fetch.jl")
include("db.jl")
include("build.jl")
include("stats.jl")
include("semantic.jl")
include("query.jl")
include("function_semantics.jl")
include("releases.jl")
include("graph_releases.jl")
include("embedding_runtime.jl")
include("audit.jl")
include("render.jl")
include("mcp.jl")
include("precompile.jl")

end
