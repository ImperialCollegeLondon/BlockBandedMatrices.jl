# using CUDAnative
# device!(0)
# using CuArrays
using GPUArrays
using BlockArrays: _BlockArray, PseudoBlockArray, BlockArray, BlockMatrix, BlockVector,
                  nblocks, Block, cumulsizes, AbstractBlockVector
using BlockBandedMatrices: BandedBlockBandedMatrix, _BandedBlockBandedMatrix,
                           blockbandwidths, subblockbandwidths, blockbandwidth,
                           BandedBlockBandedSizes
using LinearAlgebra: BLAS
using BandedMatrices: _BandedMatrix
using SharedArrays
using LazyArrays
import Distributed

import Adapt: adapt
import LinearAlgebra

############### Loot and plunder
# BlockArrays
adapt(T::Type{<:AbstractArray}, b::BlockArray) =
    _BlockArray(T.(b.blocks), b.block_sizes)
adapt(T::Type{<:AbstractArray}, b::PseudoBlockArray) = 
    PseudoBlockArray(T(b.blocks), b.block_sizes)
adapt(T::Type{<:PseudoBlockArray}, b::BlockArray) = T(b.blocks, b.block_sizes)
adapt(T::Type{<:BlockArray}, b::PseudoBlockArray) = T(b.blocks, b.block_sizes)
# CuArrays and BlockArrays
if @isdefined CuArray
  adapt(T::Type{<:CuArray}, b::PseudoBlockArray) = adapt(T, BlockArray(b))
end
###############

adapt(T::Type, b::BandedBlockBandedMatrix) =
    _BandedBlockBandedMatrix(adapt(T, b.data), b.block_sizes)


function LinearAlgebra.mul!(c::BlockVector{T},
                            A::BandedBlockBandedMatrix{T, <: BlockMatrix},
                            x::BlockVector{T}) where T
    @assert nblocks(A, 1) == nblocks(c, 1)
    @assert cumulsizes(A, 1) == cumulsizes(c, 1)
    @assert nblocks(A, 2) == nblocks(x, 1)
    @assert cumulsizes(A, 2) == cumulsizes(x, 1)

    for block in c.blocks
      fill!(block, zero(eltype(block)))
    end
    l, u = blockbandwidths(A)
    λ, μ = subblockbandwidths(A)
    N,M = nblocks(A)

    @inbounds for i = 1:N, j = max(1,i-l):min(M,i+u)
        BLAS.gbmv!('N', size(view(A, Block(i, j)), 1), λ, μ, one(T),
                   A.data.blocks[i - j + u + 1, j],
                   x.blocks[j], one(T), c.blocks[i])
    end

    c
end

function banded_mul!(c::BlockVector{T},
                     A::BandedBlockBandedMatrix{T, <: BlockMatrix},
                     x::AbstractBlockVector{T}) where T
    @assert nblocks(A, 1) == nblocks(c, 1)
    @assert cumulsizes(A, 1) == cumulsizes(c, 1)
    @assert nblocks(A, 2) == nblocks(x, 1)
    @assert cumulsizes(A, 2) == cumulsizes(x, 1)

    for block in c.blocks
      fill!(block, zero(eltype(block)))
    end
    l, u = blockbandwidths(A)
    λ, μ = subblockbandwidths(A)
    N, M = nblocks(A)

    @inbounds for i = 1:N, j = max(1,i-l):min(M,i+u)
      B = _BandedMatrix(A.data.blocks[i - j + u + 1, j],
                        size(view(A, Block(i, j)), 1), 
                        λ, μ)
      c[Block(i)] .+= Mul(B, x.blocks[j])
    end

    c
end

function nofill_mul!(Cblock::BandedBlockBandedMatrix{T, <: BlockMatrix},
                     Ablock::BandedBlockBandedMatrix{T, <: BlockMatrix},
                     Xblock::BandedBlockBandedMatrix{T, <: BlockMatrix}) where T
    @assert nblocks(Ablock, 1) == nblocks(Cblock, 1)
    @assert cumulsizes(Ablock, 1) == cumulsizes(Cblock, 1)
    @assert nblocks(Ablock, 2) == nblocks(Xblock, 1)
    @assert cumulsizes(Ablock, 2) == cumulsizes(Xblock, 1)
    @assert nblocks(Xblock, 2) == nblocks(Cblock, 2)
    @assert cumulsizes(Xblock, 2) == cumulsizes(Xblock, 2)

    lₐ, uₐ = blockbandwidths(Ablock)
    lₓ, uₓ = blockbandwidths(xblock)
    λ, μ = subblockbandwidths(Ablock)
    N,M = nblocks(Ablock)
    M, K = nblocks(Xblock)

    @inbounds for i = 1:N, j = max(1,i-lₐ):min(M,i+uₐ), k = max(1, j - lₓ):min(j + uₓ, K)
        BLAS.gbmv!('N', size(view(Ablock, Block(i, j)), 1), λ, μ, one(T),
                   Ablock.data.blocks[i - j + u + 1, j],
                   Xblock.blocks[j], one(T), Cblock.blocks[i])
    end

    Cblock
end

using Test

function testme()
  @testset "block-banded on NVIDIA gpus" begin

    @testset "BlockArray Adapters" begin
      bmat = BlockArray{Float64}(undef, [1, 1], [2, 2])
      @test adapt(JLArray, bmat) isa BlockArray{T, 2, JLArray{T, 2}} where T
      @test eltype(adapt(JLArray, bmat)) === Float64
      if @isdefined CuArray
        @test cu(bmat) isa BlockArray{T, 2, JLArray{T, 2}} where T
        @test eltype(cu(bmat)) === Float32
      end
    end

    @testset "PseudoBlockArray Adapters" begin
      bmat = PseudoBlockArray{Float64}(undef, [1, 1], [2, 2])
      @test eltype(adapt(JLArray, bmat)) === Float64
      @test adapt(JLArray, bmat) isa PseudoBlockArray
      if @isdefined CuArray
        @test !(adapt(CuArray, bmat) isa PseudoBlockArray)
        @test adapt(CuArray, bmat) isa BlockArray{T, 2, JLArray{T, 2}} where T
        @test cu(bmat) isa BlockArray{T, 2, JLArray{T, 2}} where T
        @test eltype(cu(bmat)) === Float32
      end
    end
   
    @testset "PseudoBlockArray Adapters" begin
      bmat = BandedBlockBandedMatrix{Float64}(undef, ([1, 1], [2, 2]), (1, 2), (1, 1))
      @test adapt(JLArray, bmat) isa BandedBlockBandedMatrix
      @test adapt(JLArray, bmat).data isa PseudoBlockArray{T, 2, JLArray{T, 2}} where T
      @test eltype(adapt(JLArray, bmat)) === Float64
      if @isdefined CuArray
        @test adapt(CuArray, bmat).data isa BlockArray{T, 2, CuArray{T, 2}} where T
        @test cu(bmat) isa BandedBlockBandedMatrix
        @test cu(bmat).data isa BlockArray{T, 2, JLArray{T, 2}} where T
        @test eltype(cu(bmat)) === Float32
      end
    end

    @testset "Multiplication" begin
       N, M = rand(1:20, 2)
       l, u, λ, μ = rand(0:2, 4)
       n, m = rand(max(l, u, λ, μ):20, N), rand(max(l, u, λ, μ):20, M)
       A = BandedBlockBandedMatrix{Float64}(undef, (n, m), (l, u), (λ, μ))
       A.data .= rand.()
       Ablock = adapt(BlockArray, A)
       cblock = BlockArray(Array{Float64, 1}(undef, size(A, 1)), n)
       cblock .= rand.()
       x = PseudoBlockArray(Array{Float64, 1}(undef, size(A, 2)), m)
       x .= rand.()
       xblock = adapt(BlockArray, x)
   
       @test LinearAlgebra.mul!(cblock, Ablock, xblock) ≈ A * x
       cblock .= 0
       @test banded_mul!(cblock, Ablock, xblock) ≈ A * x
    end
  end
end

using BenchmarkTools
using Statistics

function benchmarks()
  suite = BenchmarkGroup()
  suite["viabm"] = BenchmarkGroup()
  suite["pseudo"] = BenchmarkGroup()
  suite["block"] = BenchmarkGroup()
  possibles = [5, 10, 100, 500, 1000]
  for N in possibles #, n in possibles
    n = N
    suite["pseudo"]["N=$N n=$n"] = BenchmarkGroup()
    suite["block"]["N=$N n=$n"] = BenchmarkGroup()
    suite["viabm"]["N=$N n=$n"] = BenchmarkGroup()

    l, u, λ, μ = rand(0:2, 4)
    M, m = N, n
  
    A = BandedBlockBandedMatrix{Float64}(
             undef, (repeat([n], N), repeat([m], M)), (l, u), (λ, μ))
    A.data .= rand.()
    c = PseudoBlockArray(Array{Float64, 1}(undef, size(A, 1)), repeat([n], N))
    c .= rand.()
    x = PseudoBlockArray(Array{Float64, 1}(undef, size(A, 2)), repeat([m], M))
    x .= rand.()

    suite["pseudo"]["N=$N n=$n"] = @benchmarkable begin
      $c .= Mul($A, $x)
    end
    suite["block"]["N=$N n=$n"] = @benchmarkable begin
      LinearAlgebra.mul!($(adapt(BlockArray, c)), $(adapt(BlockArray, A)),
                         $(adapt(BlockArray, x)))
    end
    suite["viabm"]["N=$N n=$n"] = @benchmarkable begin
      banded_mul!($(adapt(BlockArray, c)), $(adapt(BlockArray, A)),
                  $(adapt(BlockArray, x)))
    end
  end
  suite
end

block_ratio(result, name; method=median) = 
    ratio(method(result["block"][name]), method(result["pseudo"][name]))
viabm_ratio(result, name; method=median) = 
    ratio(method(result["viabm"][name]), method(result["block"][name]))
