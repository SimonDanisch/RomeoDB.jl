# SPDX-FileCopyrightText: 2026 Simon Danisch
# SPDX-License-Identifier: AGPL-3.0-or-later

# Qwen3-Embedding as RomeoDB's embedder: loaded when Qwen3EmbeddingRunner is.
module RomeoDBQwen3EmbeddingExt

using RomeoDB, Qwen3EmbeddingRunner

RomeoDB.embeddocument(m::Qwen3Embedding, text::AbstractString) = embed(m, text)
RomeoDB.embedquery(m::Qwen3Embedding, text::AbstractString) = embed_query(m, text)
RomeoDB.embedfunction(m::Qwen3Embedding, text::AbstractString) = embed_long(m, text)
RomeoDB.embedfunctionquery(m::Qwen3Embedding, text::AbstractString) = embed_long(m,
    "Instruct: Given a Julia function implementation, retrieve Julia functions implementing the same functionality, including different algorithms and variable names.\nQuery:$text")
RomeoDB.functionmodel(m::Qwen3Embedding) = "qwen3embedding:$(basename(Qwen3EmbeddingRunner.assetdir())):capacity$(m.maxtokens):overlap64"

end
