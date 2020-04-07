#######################################################################
# Diagonalize methods
#   (All but LinearAlgebraPackage `@require` some package to be loaded)
#######################################################################
abstract type AbstractDiagonalizeMethod end

struct Diagonalizer{S<:AbstractDiagonalizeMethod,C}
    method::S
    codiag::C
    minprojection::Float64
end

## Diagonalize methods ##

function defaultmethod(h::Union{Hamiltonian,AbstractMatrix})
    if eltype(h) <: Number
        # method = issparse(h) ? ArpackPackage() : LinearAlgebraPackage()
        method = LinearAlgebraPackage()
    else
        # method = KrylovKitPackage()
        throw(ArgumentError("Methods for generic Hamiltonian eltypes not yet implemented. Consider using `flatten` on your Hamiltonian."))
    end
    return method
end

checkloaded(package::Symbol) = isdefined(Main, package) ||
    throw(ArgumentError("Package $package not loaded, need to be `using $package`."))

## LinearAlgebra ##
struct LinearAlgebraPackage{K<:NamedTuple} <: AbstractDiagonalizeMethod
    kw::K
end

LinearAlgebraPackage(; kw...) = LinearAlgebraPackage(values(kw))

function diagonalize(matrix, method::LinearAlgebraPackage)
    ϵ, ψ = eigen!(matrix; (method.kw)...)
    return ϵ, ψ
end

similarmatrix(h, ::LinearAlgebraPackage) = Matrix(similarmatrix(h))

## Arpack ##
struct ArpackPackage{K<:NamedTuple} <: AbstractDiagonalizeMethod
    kw::K
end

ArpackPackage(; kw...) = (checkloaded(:Arpack); ArpackPackage(values(kw)))

function diagonalize(matrix, method::ArpackPackage)
    ϵ, ψ = Main.Arpack.eigs(matrix; (method.kw)...)
    return ϵ, ψ
end

similarmatrix(h, ::ArpackPackage) = similarmatrix(h)

## IterativeSolvers ##

struct KrylovKitPackage{K<:NamedTuple} <: AbstractDiagonalizeMethod
    kw::K
end

KrylovKitPackage(; kw...) = (checkloaded(:KrylovKit); KrylovKitPackage(values(kw)))

function diagonalize(matrix::AbstractMatrix{M}, method::KrylovKitPackage) where {M}
    ishermitian(matrix) || throw(ArgumentError("Only Hermitian matrices supported with KrylovKitPackage for the moment"))
    origin = get(method.kw, :origin, 0.0)
    howmany = get(method.kw, :howmany, 1)
    kw´ = Base.structdiff(method.kw, NamedTuple{(:origin,:howmany)}) # Remove origin option
    lmap = shiftandinvert(matrix, origin)
    T = eltypevec(matrix)
    n = size(matrix, 2)
    x0 = rand(T, n)
    ϵ, ψ, _ = Main.KrylovKit.eigsolve(x -> lmap * x, x0, howmany, :LM; kw´...)

    ϵ´ = invertandshift(ϵ, origin)
    resize!(ϵ´, howmany)

    dimh = size(matrix, 2)
    ψ´ = Matrix{T}(undef, dimh, howmany)
    for i in 1:howmany
        copyslice!(ψ´, CartesianIndices((1:dimh, i:i)), ψ[i], CartesianIndices((1:dimh,)))
    end

    return ϵ´, ψ´
end

similarmatrix(h, ::KrylovKitPackage) = similarmatrix(h)

#######################################################################
# shift and invert methods
#######################################################################

function shiftandinvert(matrix::AbstractMatrix{Tv}, origin) where {Tv}
    cols, rows = size(matrix)
    # Shift away from real axis to avoid pivot point error in factorize
    matrix´ = diagshift!(parent(matrix), origin + im)
    F = factorize(matrix´)
    lmap = LinearMap{Tv}((x, y) -> ldiv!(x, F, y), cols, rows,
                         ismutating = true, ishermitian = false)
    return lmap
end

function diagshift!(matrix::AbstractMatrix, origin)
    matrix´ = parent(matrix)
    vals = nonzeros(matrix´)
    rowval = rowvals(matrix´)
    for col in 1:size(matrix, 2)
        found_diagonal = false
        for ptr in nzrange(matrix´, col)
            if col == rowval[ptr]
                found_diagonal = true
                vals[ptr] -= origin * I  # To respect non-scalar eltypes
                break
            end
        end
        found_diagonal || throw(error("Sparse work matrix must include the diagonal. Possible bug in `similarmatrix`."))
    end
    return matrix
end

function invertandshift(ϵ::Vector{T}, origin) where {T}
    ϵ´ = similar(ϵ, real(T))
    ϵ´ .= real(inv.(ϵ) .+ (origin + im))  # Caution: we assume a real spectrum
    return ϵ´
end

#######################################################################
# resolve_degeneracies
#######################################################################
# Tries to make states continuous at crossings. Here, ϵ needs to be sorted
function resolve_degeneracies!(ϵ, ψ, ϕs, matrix, codiag)
    issorted(ϵ, by = real) || sorteigs!(codiag.perm, ϵ, ψ)
    hasapproxruns(ϵ, codiag.degtol) || return ϵ, ψ
    ranges, ranges´ = codiag.rangesA, codiag.rangesB
    resize!(ranges, 0)
    pushapproxruns!(ranges, ϵ, 0, codiag.degtol) # 0 is an offset
    for n in codiag.matrixindices
        v = codiag.cmatrixf(ϕs, n)
        resize!(ranges´, 0)
        for (i, r) in enumerate(ranges)
            subspace = view(ψ, :, r)
            vsubspace = subspace' * v * subspace
            veigen = eigen!(Hermitian(vsubspace))
            if hasapproxruns(veigen.values, codiag.degtol)
                roffset = minimum(r) - 1 # Range offset within the ϵ vector
                pushapproxruns!(ranges´, veigen.values, roffset, codiag.degtol)
            end
            subspace .= subspace * veigen.vectors
        end
        ranges, ranges´ = ranges´, ranges
        isempty(ranges) && break
    end
    return ψ
end

# Could perhaps be better/faster using a generalized CoSort
function sorteigs!(perm, ϵ::Vector, ψ::Matrix)
    resize!(perm, length(ϵ))
    p = sortperm!(perm, ϵ, by = real)
    # permute!(ϵ, p)
    sort!(ϵ, by = real)
    Base.permutecols!!(ψ, p)
    return ϵ, ψ
end

#######################################################################
# Codiagonalizer
#######################################################################

## Codiagonalizer
## Uses velocity operators along different directions. If not enough, use finite differences
struct Codiagonalizer{S,T,F<:Function}
    cmatrixf::F
    matrixindices::UnitRange{Int}
    directions::Vector{S}
    degtol::T
    rangesA::Vector{UnitRange{Int}} # Prealloc buffer for degeneray ranges
    rangesB::Vector{UnitRange{Int}} # Prealloc buffer for degeneray ranges
    perm::Vector{Int}               # Prealloc for sortperm!
end

function codiagonalizer(h::Hamiltonian, matrix, mesh::Mesh{L}; kw...) where {L}
    directions = velocitydirections(Val(L); kw...)
    ndirs = length(directions)
    matrixindices = 1:(2 * ndirs + 1)
    degtol = sqrt(eps(realtype(h)))
    delta = meshdelta(mesh)
    delta = iszero(delta) ? degtol : delta
    cmatrixf(ϕs, n) =
        if n <= ndirs
            bloch!(matrix, h, ϕs, dn -> im * directions[n]' * dn)
        elseif n <= 2ndirs # resort to finite differences
            bloch!(matrix, h, ϕs + delta * directions[n - ndirs])
        else # use a fixed random matrix
            randomfill!(matrix)
        end
    return Codiagonalizer(cmatrixf, matrixindices, directions, degtol, UnitRange{Int}[], UnitRange{Int}[], Int[])
end

function codiagonalizer(matrixf::Function, matrix::AbstractMatrix{T}, mesh::Mesh{L}; kw...) where {L,T}
    directions = velocitydirections(Val(L); kw...)
    ndirs = length(directions)
    matrixindices = 1:(ndirs + 1)
    degtol = sqrt(eps(real(eltype(T))))
    delta = meshdelta(mesh)
    delta = iszero(delta) ? degtol : delta
    cmatrixf(ϕs, n) =
        if n <= ndirs # finite differences
            matrixf((ϕs + delta * directions[n - ndirs])...)
        else # use a fixed random matrix
            randomfill!(matrix)
        end
    return Codiagonalizer(cmatrixf, matrixindices, directions, degtol, UnitRange{Int}[], UnitRange{Int}[], Int[])
end

function velocitydirections(::Val{L}; direlements = 0:1, onlypositive = true) where {L}
    directions = vec(SVector{L,Int}.(Iterators.product(ntuple(_ -> direlements, Val(L))...)))
    onlypositive && filter!(ispositive, directions)
    unique!(normalize, directions)
    sort!(directions, by = norm, rev = false)
    return directions
end

meshdelta(mesh::Mesh{<:Any,T}) where {T} = T(0.1) * first(minmax_edge_length(mesh))

function randomfill!(matrix::SparseMatrixCSC, seed = 1234)
    Random.seed!(seed)
    rand!(nonzeros(matrix))  ## CAREFUL: this will be non-hermitian
    return matrix
end

function randomfill!(matrix::AbstractArray{T}, seed = 1234) where {T}
    Random.seed!(seed)
    fill!(matrix, zero(T))
    for i in 1:minimum(size(matrix))
        r = rand(T)
        @inbounds matrix[i, i] = r + r'
    end
    return matrix
end