# SPDX-FileCopyrightText: 2026 Simon Danisch
# SPDX-License-Identifier: AGPL-3.0-or-later

# The JLL registers its ICD. Restrict the loader before importing the runner so
# this test cannot silently pass on a hardware GPU present on the test machine.
using Lavapipe_jll
ENV["VK_DRIVER_FILES"] = Lavapipe_jll.lvp_icd
ENV["VK_ICD_FILENAMES"] = Lavapipe_jll.lvp_icd
delete!(ENV, "VK_ADD_DRIVER_FILES")
ENV["JULIA_GLFW_PLATFORM"] = "null"

using Test, LinearAlgebra, Pkg, RomeoDB
using Qwen3EmbeddingRunner
using Qwen3EmbeddingRunner: Mantle, DNNKernels, JSON3

@testset "Qwen embeddings on Lavapipe_jll" begin
    devices = Mantle.devices()
    @info "CI Vulkan devices" devices
    @test length(devices) == 1
    device = only(devices)
    @test device.kind == :cpu
    @test occursin("llvmpipe", lowercase(device.name * " " * device.driver))

    # Neither querying the model nor downloading its reference should provision
    # the full ecosystem database or graph.
    bindings = joinpath(pkgdir(RomeoDB), "Artifacts.toml")
    datahashes = [Pkg.Artifacts.artifact_hash(name, bindings) for name in keys(RomeoDB.TOML.parsefile(bindings))]
    installed = Pkg.Artifacts.artifact_exists.(datahashes)

    refs = Qwen3EmbeddingRunner.refsdir()
    reference = DNNKernels.readsafetensors(joinpath(refs, "reference.safetensors"))["embeddings"]
    metadata = JSON3.read(read(joinpath(refs, "reference.json"), String))
    model = qwen3embedding(; backend = Mantle.Device(device.index))

    # Short forward passes keep software-renderer CI affordable. They exercise the
    # real exported weights, tokenizer, Vulkan kernels and RomeoDB extension.
    query = RomeoDB.embedquery(model, "ocean sim")
    document = RomeoDB.embeddocument(model, String(metadata.texts[5]))
    @test length(query) == length(document) == 1024
    @test all(isfinite, query) && all(isfinite, document)
    @test norm(query) ≈ 1 atol = 1e-5
    @test norm(document) ≈ 1 atol = 1e-5
    @test dot(query, reference[:, 2]) > 0.999
    @test dot(document, reference[:, 5]) > 0.999
    nq = Int(metadata.queries)
    @test argmax(reference[:, nq+1:end]' * query) == 2 # ocean document
    @test norm(RomeoDB.compact_function_vector(document, 256)) ≈ 1 atol = 1e-5
    body = RomeoDB.functiontext("sum_of_squares(xs) = sum(abs2, xs)")
    function_vector = RomeoDB.embedfunction(model, body)
    @test length(function_vector) == 1024
    @test all(isfinite, function_vector)
    @test norm(function_vector) ≈ 1 atol = 1e-5
    @test Pkg.Artifacts.artifact_exists.(datahashes) == installed
end
