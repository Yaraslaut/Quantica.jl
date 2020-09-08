using Quantica.RegionPresets: Region

#######################################################################
# Onsite/Hopping selectors
#######################################################################
abstract type Selector{M,S} end

struct SiteSelector{M,S} <: Selector{M,S}
    region::M
    sublats::S  # NTuple{N,NameType} (unresolved) or Vector{Int} (resolved on a lattice)
end

struct HopSelector{M,S,D,T} <: Selector{M,S}
    region::M
    sublats::S  # NTuple{N,Pair{NameType,NameType}} (unres) or Vector{Pair{Int,Int}} (res)
    dns::D
    range::T
end

"""
    siteselector(; region = missing, sublats = missing)

Return a `SiteSelector` object that can be used to select sites in a lattice contained
within the specified region and sublattices. Only sites at position `r` in sublattice with
name `s::NameType` will be selected if `region(r) && s in sublats` is true. Any missing
`region` or `sublat` will not be used to constraint the selection.

The keyword `sublats` allows the following formats:

    sublats = :A           # Onsite on sublat :A only
    sublats = (:A,)        # Same as above
    sublats = (:A, :B)     # Onsite on sublat :A and :B
"""
siteselector(; region = missing, sublats = missing) =
    SiteSelector(region, sanitize_sublats(sublats))

"""
    hopselector(; region = missing, sublats = missing, dn = missing, range = missing)

Return a `HopSelector` object that can be used to select hops between two sites in a
lattice. Only hops between two sites at positions `r₁ = r - dr/2` and `r₂ = r + dr`,
belonging to unit cells at integer distance `dn´` and to sublattices `s₁` and `s₂` will be
selected if: `region(r, dr) && s in sublats && dn´ in dn && norm(dr) <= range`. If any of
these is `missing` it will not be used to constraint the selection.

The keyword `dn` can be a `Tuple`/`Vector`/`SVector` of `Int`s, or a tuple thereof. The
keyword `sublats` allows the following formats:

    sublats = :A => :B                 # Hopping from :A to :B sublattices
    sublats = (:A => :B,)              # Same as above
    sublats = (:A => :B, :C => :D)     # Hopping from :A to :B or :C to :D
    sublats = (:A, :C) .=> (:B, :D)    # Broadcasted pairs, same as above
    sublats = (:A, :C) => (:B, :D)     # Direct product, (:A=>:B, :A=:D, :C=>:B, :C=>D)
"""
hopselector(; region = missing, sublats = missing, dn = missing, range = missing) =
    HopSelector(region, sanitize_sublatpairs(sublats), sanitize_dn(dn), sanitize_range(range))

sanitize_sublats(s::Missing) = missing
sanitize_sublats(s::Integer) = (nametype(s),)
sanitize_sublats(s::NameType) = (s,)
sanitize_sublats(s::Tuple) = nametype.(s)
sanitize_sublats(s::Tuple{}) = ()
sanitize_sublats(n) = throw(ErrorException(
    "`sublats` for `onsite` must be either `missing`, a sublattice name or a tuple of names, see `onsite` for details"))

sanitize_sublatpairs(s::Missing) = missing
sanitize_sublatpairs(p::Pair{<:Union{NameType,Integer}, <:Union{NameType,Integer}}) =
    (ensurenametype(p),)
sanitize_sublatpairs(pp::Pair) =
    ensurenametype.(tupletopair.(tupleproduct(first(pp), last(pp))))
sanitize_sublatpairs(ps::Tuple) = tuplejoin(sanitize_sublatpairs.(ps)...)
sanitize_sublatpairs(s) = throw(ErrorException(
    "`sublats` for `hopping` must be either `missing` or a series of sublattice `Pair`s, see `hopping` for details"))

ensurenametype((s1, s2)::Pair) = nametype(s1) => nametype(s2)

sanitize_dn(dn::Missing) = missing
sanitize_dn(dn::Tuple{Vararg{Number,N}}) where {N} = (_sanitize_dn(dn),)
sanitize_dn(dn) = (_sanitize_dn(dn),)
sanitize_dn(dn::Tuple) = _sanitize_dn.(dn)
_sanitize_dn(dn::Tuple{Vararg{Number,N}}) where {N} = SVector{N,Int}(dn)
_sanitize_dn(dn::SVector{N}) where {N} = SVector{N,Int}(dn)
_sanitize_dn(dn::Vector) = SVector{length(dn),Int}(dn)

sanitize_range(::Missing) = missing
sanitize_range(range::Real) = isfinite(range) ? float(range) + sqrt(eps(float(range))) : float(range)

sublats(lat::AbstractLattice, s::SiteSelector{<:Any,Missing}) = collect(1:nsublats(lat))

function sublats(lat::AbstractLattice, s::SiteSelector{<:Any,<:Tuple})
    names = lat.unitcell.names
    ss = Int[]
    for name in s.sublats
        i = findfirst(isequal(name), names)
        i !== nothing && push!(ss, i)
    end
    return ss
end

function sublats(lat::AbstractLattice, s::HopSelector{<:Any,<:Tuple})
    names = lat.unitcell.names
    ss = Pair{Int,Int}[]
    for (nsrc, ndst) in s.sublats
        isrc = findfirst(isequal(nsrc), names)
        idst = findfirst(isequal(ndst), names)
        isrc !== nothing && idst !== nothing && push!(ss, isrc => idst)
    end
    return ss
end

sublats(lat::AbstractLattice, s::HopSelector{<:Any,Missing}) =
    tupletopair.(vec(collect(Iterators.product(1:nsublats(lat), 1:nsublats(lat)))))

# selector already resolved for a lattice
sublats(lat, s::Selector{<:Any,<:Vector}) = s.sublats

# API

resolve(s::HopSelector, lat::AbstractLattice) =
    HopSelector(s.region, sublats(lat, s), _checkdims(s.dns, lat), s.range)
resolve(s::SiteSelector, lat::AbstractLattice) = SiteSelector(s.region, sublats(lat, s))

_checkdims(dns::Missing, lat::AbstractLattice{E,L}) where {E,L} = dns
_checkdims(dns::Tuple{Vararg{SVector{L,Int}}}, lat::AbstractLattice{E,L}) where {E,L} = dns
_checkdims(dns, lat::AbstractLattice{E,L}) where {E,L} =
    throw(DimensionMismatch("Specified cell distance `dn` does not match lattice dimension $L"))

# are sites at (i,j) and (dni, dnj) or (dn, 0) selected?
(s::SiteSelector)(lat::AbstractLattice, (i, j)::Tuple, (dni, dnj)::Tuple{SVector, SVector}) =
    isonsite((i, j), (dni, dnj)) && isinregion(i, dni, s.region, lat) && isinsublats(sublat(lat, i), s.sublats)

(s::HopSelector)(lat::AbstractLattice, inds, dns) =
    !isonsite(inds, dns) && isinregion(inds, dns, s.region, lat) && isindns(dns, s.dns) &&
    isinrange(inds, s.range, lat) && isinsublats(tupletopair(sublat.(Ref(lat), inds)), s.sublats)

isonsite((i, j), (dni, dnj)) = i == j && dni == dnj

isinregion(i::Int, ::Missing, lat) = true
isinregion(i::Int, dn, ::Missing, lat) = true
isinregion(i::Int, region::Union{Function,Region}, lat) = region(sites(lat)[i])
isinregion(i::Int, dn, region::Union{Function,Region}, lat) = region(sites(lat)[i] + bravais(lat) * dn)

isinregion(is::Tuple{Int,Int}, dns, ::Missing, lat) = true
function isinregion((row, col)::Tuple{Int,Int}, (dnrow, dncol), region::Union{Function,Region}, lat)
    br = bravais(lat)
    r, dr = _rdr(sites(lat)[col] + br * dncol, sites(lat)[row] + br * dnrow)
    return region(r, dr)
end

isinsublats(s::Int, ::Missing) = true
isinsublats(s::Int, sublats::Vector{Int}) = s in sublats
isinsublats(ss::Pair{Int,Int}, ::Missing) = true
isinsublats(ss::Pair{Int,Int}, sublats::Vector{Pair{Int,Int}}) = ss in sublats
isinsublats(s, sublats) =
    throw(ArgumentError("Sublattices $sublats in selector are not resolved."))

isindns((dnrow, dncol)::Tuple{SVector,SVector}, dns) = isindns(dnrow - dncol, dns)
isindns(dn::SVector{L,Int}, dns::Tuple{Vararg{SVector{L,Int}}}) where {L} = dn in dns
isindns(dn::SVector, dns::Missing) = true
isindns(dn, dns) =
    throw(ArgumentError("Cell distance dn in selector is incompatible with Lattice."))

isinrange(inds, ::Missing, lat) = true
isinrange((row, col)::Tuple{Int,Int}, range::Number, lat) =
    norm(sites(lat)[col] - sites(lat)[row]) <= range

# merge non-missing fields of s´ into s
merge_non_missing(s::SiteSelector, s´::SiteSelector) =
    SiteSelector(merge_non_missing.(
        (s.region,  s.sublats),
        (s´.region, s´.sublats))...)
merge_non_missing(s::HopSelector, s´::HopSelector) =
    HopSelector(merge_non_missing.(
        (s.region,  s.sublats,  s.dns,  s.range),
        (s´.region, s´.sublats, s´.dns, s´.range))...)
merge_non_missing(o, o´::Missing) = o
merge_non_missing(o, o´) = o´

Base.adjoint(s::SiteSelector) = s
function Base.adjoint(s::HopSelector)
    # is_unconstrained_selector(s) &&
    #     @warn("Taking the adjoint of an unconstrained hopping is likely unintended")
    region´ = _adjoint(s.region)
    sublats´ = _adjoint.(s.sublats)
    dns´ = _adjoint.(s.dns)
    range = s.range
    return HopSelector(region´, sublats´, dns´, range)
end

_adjoint(::Missing) = missing
_adjoint(f::Function) = (r, dr) -> f(r, -dr)
_adjoint(t::Pair) = reverse(t)
_adjoint(t::SVector) = -t

# is_unconstrained_selector(s::HopSelector{Missing,Missing,Missing}) = true
# is_unconstrained_selector(s::HopSelector) = false

#######################################################################
# Tightbinding types
#######################################################################
abstract type TightbindingModelTerm end
abstract type AbstractOnsiteTerm <: TightbindingModelTerm end
abstract type AbstractHoppingTerm <: TightbindingModelTerm end

struct TightbindingModel{N,T<:Tuple{Vararg{TightbindingModelTerm,N}}}
    terms::T
end

struct OnsiteTerm{F,S<:SiteSelector,C} <: AbstractOnsiteTerm
    o::F
    selector::S
    coefficient::C
end

struct HoppingTerm{F,S<:HopSelector,C} <: AbstractHoppingTerm
    t::F
    selector::S
    coefficient::C
end

#######################################################################
# TightbindingModel API
#######################################################################
terms(t::TightbindingModel) = t.terms

TightbindingModel(ts::TightbindingModelTerm...) = TightbindingModel(ts)

# (m::TightbindingModel)(r, dr) = sum(t -> t(r, dr), m.terms)

# External API #

Base.:*(x, m::TightbindingModel) = TightbindingModel(x .* m.terms)
Base.:*(m::TightbindingModel, x) = x * m
Base.:-(m::TightbindingModel) = TightbindingModel((-1) .* m.terms)

Base.:+(m::TightbindingModel, t::TightbindingModel) = TightbindingModel((m.terms..., t.terms...))
Base.:-(m::TightbindingModel, t::TightbindingModel) = m + (-t)

function Base.show(io::IO, m::TightbindingModel{N}) where {N}
    ioindent = IOContext(io, :indent => "  ")
    print(io, "TightbindingModel{$N}: model with $N terms", "\n")
    foreach(t -> print(ioindent, t, "\n"), m.terms)
end

#######################################################################
# TightbindingModelTerm API
#######################################################################
OnsiteTerm(t::OnsiteTerm, os::SiteSelector) =
    OnsiteTerm(t.o, os, t.coefficient)

(o::OnsiteTerm{<:Function})(r,dr) = o.coefficient * o.o(r)
(o::OnsiteTerm)(r,dr) = o.coefficient * o.o

HoppingTerm(t::HoppingTerm, os::HopSelector) =
    HoppingTerm(t.t, os, t.coefficient)

(h::HoppingTerm{<:Function})(r, dr) = h.coefficient * h.t(r, dr)
(h::HoppingTerm)(r, dr) = h.coefficient * h.t

sublats(t::TightbindingModelTerm, lat) = sublats(lat, t.selector)

sublats(m::TightbindingModel) = (t -> t.selector.sublats).(terms(m))

displayparameter(::Type{<:Function}) = "Function"
displayparameter(::Type{T}) where {T} = "$T"

function Base.show(io::IO, o::OnsiteTerm{F}) where {F}
    i = get(io, :indent, "")
    print(io,
"$(i)OnsiteTerm{$(displayparameter(F))}:
$(i)  Sublattices      : $(o.selector.sublats === missing ? "any" : o.selector.sublats)
$(i)  Coefficient      : $(o.coefficient)")
end

function Base.show(io::IO, h::HoppingTerm{F}) where {F}
    i = get(io, :indent, "")
    print(io,
"$(i)HoppingTerm{$(displayparameter(F))}:
$(i)  Sublattice pairs : $(h.selector.sublats === missing ? "any" : h.selector.sublats)
$(i)  dn cell distance : $(h.selector.dns === missing ? "any" : h.selector.dns)
$(i)  Hopping range    : $(round(h.selector.range, digits = 6))
$(i)  Coefficient      : $(h.coefficient)")
end

# External API #
"""
    onsite(o; region = missing, sublats = missing)

Create an `TightbindingModel` with a single `OnsiteTerm` that applies an onsite energy `o`
to a `Lattice` when creating a `Hamiltonian` with `hamiltonian`.

The onsite energy `o` can be a number, an `SMatrix`, a `UniformScaling` (e.g. `3*I`) or a
function of the form `r -> ...` for a position-dependent onsite energy.

The dimension of `o::AbstractMatrix` must match the orbital dimension of applicable
sublattices (see also `orbitals` option for `hamiltonian`). If `o::UniformScaling` it will
be converted to an identity matrix of the appropriate size when applied to multiorbital
sublattices. Similarly, if `o::SMatrix` it will be truncated or padded to the appropriate
size.

    onsite(model::TightbindingModel; kw...)

Return a `TightbindingModel` with only the onsite terms of `model`. Any non-missing `kw` is
applied to all such terms.

# Keyword arguments

Keywords are the same as for `siteselector`. Only sites at position `r` in sublattice with
name `s::NameType` will be selected if `region(r) && s in sublats` is true. Any missing
`region` or `sublat` will not be used to constraint the selection.

The keyword `sublats` allows the following formats:

    sublats = :A           # Onsite on sublat :A only
    sublats = (:A,)        # Same as above
    sublats = (:A, :B)     # Onsite on sublat :A and :B

# Combining models

`OnsiteTerm`s and `HoppingTerm`s created with `onsite` or `hopping` can added or substracted
together or be multiplied by scalars to build more complicated `TightbindingModel`s, e.g.
`onsite(1) - 3 * hopping(2)`

# Examples

```jldoctest
julia> model = onsite(1, sublats = (:A,:B)) - 2 * hopping(2, sublats = :A=>:A)
TightbindingModel{2}: model with 2 terms
  OnsiteTerm{Int64}:
    Sublattices      : (:A, :B)
    Coefficient      : 1
  HoppingTerm{Int64}:
    Sublattice pairs : (:A => :A,)
    dn cell distance : any
    Hopping range    : 1.0
    Coefficient      : -2

julia> newmodel = onsite(model; sublats = :A) + hopping(model)
TightbindingModel{2}: model with 2 terms
  OnsiteTerm{Int64}:
    Sublattices      : (:A,)
    Coefficient      : 1
  HoppingTerm{Int64}:
    Sublattice pairs : (:A => :A,)
    dn cell distance : any
    Hopping range    : 1.0
    Coefficient      : -2

julia> LatticePresets.honeycomb() |> hamiltonian(onsite(r->@SMatrix[1 2; 3 4]), orbitals = Val(2))
Hamiltonian{<:Lattice} : Hamiltonian on a 2D Lattice in 2D space
  Bloch harmonics  : 1 (SparseMatrixCSC, sparse)
  Harmonic size    : 2 × 2
  Orbitals         : ((:a, :a), (:a, :a))
  Element type     : 2 × 2 blocks (Complex{Float64})
  Onsites          : 2
  Hoppings         : 0
  Coordination     : 0.0
```

# See also:
    `hopping`
"""
onsite(o; kw...) = onsite(o, siteselector(; kw...))

onsite(o, selector::Selector) = TightbindingModel(OnsiteTerm(o, selector, 1))

onsite(m::TightbindingModel, selector::Selector) =
    TightbindingModel(_onlyonsites(selector, m.terms...))

_onlyonsites(s, t::OnsiteTerm, args...) =
    (OnsiteTerm(t, merge_non_missing(t.selector, s)), _onlyonsites(s, args...)...)
_onlyonsites(s, t::HoppingTerm, args...) = (_onlyonsites(s, args...)...,)
_onlyonsites(s) = ()

"""
    hopping(t; region = missing, sublats = missing, dn = missing, range = 1, plusadjoint = false)

Create an `TightbindingModel` with a single `HoppingTerm` that applies a hopping `t` to a
`Lattice` when creating a `Hamiltonian` with `hamiltonian`.

The hopping amplitude `t` can be a number, an `SMatrix`, a `UniformScaling` (e.g. `3*I`) or
a function of the form `(r, dr) -> ...` for a position-dependent hopping (`r` is the bond
center, and `dr` the bond vector). If `sublats` is specified as a sublattice name pair, or
tuple thereof, `hopping` is only applied between sublattices with said names.

The dimension of `t::AbstractMatrix` must match the orbital dimension of applicable
sublattices (see also `orbitals` option for `hamiltonian`). If `t::UniformScaling` it will
be converted to a (possibly rectangular) identity matrix of the appropriate size when
applied to multiorbital sublattices. Similarly, if `t::SMatrix` it will be truncated or
padded to the appropriate size.

`OnsiteTerm`s and `HoppingTerm`s created with `onsite` or `hopping` can be added or
substracted together to build more complicated `TightbindingModel`s.

    hopping(model::TightbindingModel; kw...)

Return a `TightbindingModel` with only the hopping terms of `model`. Any non-missing `kw` is
applied to all such terms.

# Keyword arguments

Most keywords are the same as for `hopselector`. Only hoppings between two sites at
positions `r₁ = r - dr/2` and `r₂ = r + dr`, belonging to unit cells at integer distance
`dn´` and to sublattices `s₁` and `s₂` will be selected if: `region(r, dr) && s in sublats
&& dn´ in dn && norm(dr) <= range`. If any of these is `missing` it will not be used to
constraint the selection. Note that the default `range` is 1, not `missing`.

The keyword `dn` can be a `Tuple`/`Vector`/`SVector` of `Int`s, or a tuple thereof. The
keyword `sublats` allows the following formats:

    sublats = :A => :B                 # Hopping from :A to :B sublattices
    sublats = (:A => :B,)              # Same as above
    sublats = (:A => :B, :C => :D)     # Hopping from :A to :B or :C to :D
    sublats = (:A, :C) .=> (:B, :D)    # Broadcasted pairs, same as above
    sublats = (:A, :C) => (:B, :D)     # Direct product, (:A=>:B, :A=:D, :C=>:B, :C=>D)

The keyword `plusadjoint` produces a model with the input hopping term plus its adjoint.
Note that this substitution is made before multiplying by any coefficient, so that
`im*hopping(..., plusadjoint = true) == im*(hopping(...) + hopping(...)')`.

# Combining models

`OnsiteTerm`s and `HoppingTerm`s created with `onsite` or `hopping` can added or substracted
together or be multiplied by scalars to build more complicated `TightbindingModel`s, e.g.
`onsite(1) - 3 * hopping(2)`

# Examples

```jldoctest
julia> model = 3 * onsite(1) - hopping(2, dn = ((1,2), (0,0)), sublats = :A=>:B)
TightbindingModel{2}: model with 2 terms
  OnsiteTerm{Int64}:
    Sublattices      : any
    Coefficient      : 3
  HoppingTerm{Int64}:
    Sublattice pairs : (:A => :B,)
    dn cell distance : ([1, 2], [0, 0])
    Hopping range    : 1.0
    Coefficient      : -1

julia> newmodel = onsite(model) + hopping(model, range = 2)
TightbindingModel{2}: model with 2 terms
  OnsiteTerm{Int64}:
    Sublattices      : any
    Coefficient      : 3
  HoppingTerm{Int64}:
    Sublattice pairs : (:A => :B,)
    dn cell distance : ([1, 2], [0, 0])
    Hopping range    : 2.0
    Coefficient      : -1

julia> LatticePresets.honeycomb() |> hamiltonian(hopping((r,dr) -> cos(r[1]), sublats = (:A,:B) => (:A,:B)))
Hamiltonian{<:Lattice} : Hamiltonian on a 2D Lattice in 2D space
  Bloch harmonics  : 7 (SparseMatrixCSC, sparse)
  Harmonic size    : 2 × 2
  Orbitals         : ((:a,), (:a,))
  Element type     : scalar (Complex{Float64})
  Onsites          : 0
  Hoppings         : 18
  Coordination     : 9.0
```

# See also:
    `onsite`
"""
function hopping(t; plusadjoint = false, range = 1, kw...)
    hop = hopping(t, hopselector(; range = range, kw...))
    return plusadjoint ? hop + hop' : hop
end
hopping(t, selector) = TightbindingModel(HoppingTerm(t, selector, 1))

hopping(m::TightbindingModel, selector::Selector) =
    TightbindingModel(_onlyhoppings(selector, m.terms...))

_onlyhoppings(s, t::OnsiteTerm, args...) = (_onlyhoppings(s, args...)...,)
_onlyhoppings(s, t::HoppingTerm, args...) =
    (HoppingTerm(t, merge_non_missing(t.selector, s)), _onlyhoppings(s, args...)...)
_onlyhoppings(s) = ()

Base.:*(x, o::OnsiteTerm) =
    OnsiteTerm(o.o, o.selector, x * o.coefficient)
Base.:*(x, t::HoppingTerm) = HoppingTerm(t.t, t.selector, x * t.coefficient)
Base.:*(t::TightbindingModelTerm, x) = x * t
Base.:-(t::TightbindingModelTerm) = (-1) * t

Base.adjoint(t::TightbindingModel) = TightbindingModel(adjoint.(terms(t)))
Base.adjoint(t::OnsiteTerm{Function}) = OnsiteTerm(r -> t.o(r)', t.selector, t.coefficient')
Base.adjoint(t::OnsiteTerm) = OnsiteTerm(t.o', t.selector, t.coefficient')
Base.adjoint(t::HoppingTerm{Function}) = HoppingTerm((r, dr) -> t.t(r, -dr)', t.selector', t.coefficient')
Base.adjoint(t::HoppingTerm) = HoppingTerm(t.t', t.selector', t.coefficient')

#######################################################################
# offdiagonal
#######################################################################
"""
    offdiagonal(model, lat, nsublats::NTuple{N,Int})

Build a restricted version of `model` that applies only to off-diagonal blocks formed by
sublattice groups of size `nsublats`.
"""
offdiagonal(m::TightbindingModel, lat, nsublats) =
    TightbindingModel(offdiagonal.(m.terms, Ref(lat), Ref(nsublats)))

offdiagonal(o::OnsiteTerm, lat, nsublats) =
    throw(ArgumentError("No onsite terms allowed in off-diagonal coupling"))

function offdiagonal(t::HoppingTerm, lat, nsublats)
    selector´ = resolve(t.selector, lat)
    s = selector´.sublats
    sr = sublatranges(nsublats...)
    filter!(spair ->  findblock(first(spair), sr) != findblock(last(spair), sr), s)
    return HoppingTerm(t.t, selector´, t.coefficient)
end

sublatranges(i::Int, is::Int...) = _sublatranges((1:i,), is...)
_sublatranges(rs::Tuple, i::Int, is...) = _sublatranges((rs..., last(last(rs)) + 1: last(last(rs)) + i), is...)
_sublatranges(rs::Tuple) = rs

findblock(s, sr) = findfirst(r -> s in r, sr)

#######################################################################
# @onsite! and @hopping!
#######################################################################
abstract type ElementModifier{N,F,S} end

struct ParametricFunction{N,F,P<:Val}
    f::F
    params::P
end

ParametricFunction{N}(f::F, p::P) where {N,F,P} = ParametricFunction{N,F,P}(f, p)

(pf::ParametricFunction)(args...; kw...) = pf.f(args...; kw...)

struct OnsiteModifier{N,F<:ParametricFunction{N},S<:Selector} <: ElementModifier{N,F,S}
    f::F
    selector::S
end

OnsiteModifier(f, selector) = OnsiteModifier(f, selector, false)

struct HoppingModifier{N,F<:ParametricFunction{N},S<:Selector} <: ElementModifier{N,F,S}
    f::F
    selector::S
end

HoppingModifier(f, selector) = HoppingModifier(f, selector, false)

const UniformModifier = ElementModifier{1}
const UniformHoppingModifier = HoppingModifier{1}
const UniformOnsiteModifier = OnsiteModifier{1}

"""
    parameters(p::ElementModifier...)

Return the parameter names for one or several  `ElementModifier` created with `@onsite!` or
`@hopping!`
"""
parameters(ms::ElementModifier...) = mergetuples(_parameters.(ms)...)
_parameters(m::ElementModifier) = _parameters(m.f)
_parameters(pf::ParametricFunction) = pf.params


"""
    @onsite!(args -> body; kw...)

Create an `ElementModifier`, to be used with `parametric`, that applies `f = args -> body`
to onsite energies specified by `kw` (see `onsite` for details  on possible `kw`s). The form
of `args -> body` may be `(o; params...) -> ...` or `(o, r; params...) -> ...` if the
modification is position (`r`) dependent. Keyword arguments `params` are optional, and
include any parameters that `body` depends on that the user may want to tune.

# See also:
    `@hopping!`, `parametric`
"""
macro onsite!(kw, f)
    f, N, params = get_f_N_params(f, "Only @onsite!(args -> body; kw...) syntax supported")
    return esc(:(Quantica.OnsiteModifier(Quantica.ParametricFunction{$N}($f, $(Val(params))), Quantica.siteselector($kw))))
end

macro onsite!(f)
    f, N, params = get_f_N_params(f, "Only @onsite!(args -> body; kw...) syntax supported")
    return esc(:(Quantica.OnsiteModifier(Quantica.ParametricFunction{$N}($f, $(Val(params))), Quantica.siteselector())))
end

"""
    @hopping!(args -> body; kw...)

Create an `ElementModifier`, to be used with `parametric`, that applies `f = args -> body`
to hoppings energies specified by `kw` (see `hopping` for details on possible `kw`s). The
form of `args -> body` may be `(t; params...) -> ...` or `(t, r, dr; params...) -> ...` if
the modification is position (`r`, `dr`) dependent. Keyword arguments `params` are optional,
and include any parameters that `body` depends on that the user may want to tune.

# See also:
    `@onsite!`, `parametric`
"""
macro hopping!(kw, f)
    f, N, params = get_f_N_params(f, "Only @hopping!(args -> body; kw...) syntax supported")
    return esc(:(Quantica.HoppingModifier(Quantica.ParametricFunction{$N}($f, $(Val(params))), Quantica.hopselector($kw))))
end

macro hopping!(f)
    f, N, params = get_f_N_params(f, "Only @hopping!(args -> body; kw...) syntax supported")
    return esc(:(Quantica.HoppingModifier(Quantica.ParametricFunction{$N}($f, $(Val(params))), Quantica.hopselector())))
end

# Extracts normalized f, number of arguments and kwarg names from an anonymous function f
function get_f_N_params(f, msg)
    (f isa Expr && f.head == :->) || throw(ArgumentError(msg))
    d = ExprTools.splitdef(f)
    kwargs = convert(Vector{Any}, get!(d, :kwargs, []))
    d[:kwargs] = kwargs  # in case it wasn't Vector{Any} originally
    if isempty(kwargs)
        params = ()
        push!(kwargs, :(_...))  # normalization : append _... to kwargs
    else
        params = get_kwname.(kwargs) |> Tuple
        if !isempty(params) && last(params) == :...
            params = tuplemost(params)  # drop _... kwarg from params
        else
            push!(kwargs, :(_...))  # normalization : append _... to kwargs
        end
    end
    N = haskey(d, :args) ? length(d[:args]) : 0
    f´ = ExprTools.combinedef(d)
    return f´, N, params
end

get_kwname(x::Symbol) = x
get_kwname(x::Expr) = x.head === :kw ? x.args[1] : x.head  # x.head == :...

resolve(o::OnsiteModifier, lat) = OnsiteModifier(o.f, resolve(o.selector, lat))

resolve(h::HoppingModifier, lat) = HoppingModifier(h.f, resolve(h.selector, lat))

resolve(t::Tuple, lat) = _resolve(lat, t...)
_resolve(lat, t, ts...) = (resolve(t, lat), _resolve(lat, ts...)...)
_resolve(lat) = ()

# Intended for resolved ElementModifier{N} only. The N is the number of arguments accepted.
@inline (o!::UniformOnsiteModifier)(o, r; kw...) = o!(o; kw...)
@inline (o!::UniformOnsiteModifier)(o, r, dr; kw...) = o!(o; kw...)
@inline (o!::UniformOnsiteModifier)(o; kw...) = o!.f(o; kw...)
@inline (o!::OnsiteModifier)(o, r, dr; kw...) = o!(o, r; kw...)
@inline (o!::OnsiteModifier)(o, r; kw...) = o!.f(o, r; kw...)

@inline (h!::UniformHoppingModifier)(t, r, dr; kw...) = h!(t; kw...)
@inline (h!::UniformHoppingModifier)(t; kw...) = h!.f(t; kw...)
@inline (h!::HoppingModifier)(t, r, dr; kw...) = h!.f(t, r, dr; kw...)

#######################################################################
# kets
#######################################################################

struct KetModel{M<:TightbindingModel}
    model::M
    normalized::Bool
    maporbitals::Bool
end

function Base.show(io::IO, k::KetModel{M}) where {N,M<:TightbindingModel{N}}
    ioindent = IOContext(io, :indent => "  ")
    print(io, "KetModel{$N}: model with $N terms
  Normalized   : $(k.normalized)
  Map orbitals : $(k.maporbitals)")
    foreach(t -> print(ioindent, "\n", t), k.model.terms)
end

"""
    ket(a; region = missing, sublats = missing, normalized = true, maporbitals = false)

Create an `KetModel` of amplitude `a` on the specified `region` and `sublats`. The amplitude
`a` can be a number, an `SVector`, or a function of the form `r -> ...` for a
position-dependent amplitude.

Unless `maporbitals = true`, the dimension of `a::AbstractVector` must match the orbital
dimension of applicable sublattices (see also `orbitals` option for `hamiltonian`).

One or more `k::KetModel` can be converted to a `Vector` or `Matrix` representation
corresponding to Hamiltonian `h` with `Vector(k, h)` and `Matrix(k, h)`, see `Vector` and
`Matrix`.

# Keyword arguments

Keyword `normalized` indicates whether to force normalization of the ket when the `KetModel`
is applied to a specific Hamiltonian.

If keyword `maporbitals == true` and `a` is a scalar or a scalar function, `a` will be
applied to each orbital independently. This is particularly useful in multiorbital systems
with random amplitudes, e.g. `a = randn()`. If `a` is not a scalar, a `convert` error will
be thrown.

Keywords `region` and `sublats` are the same as for `siteselector`. Only sites at position
`r` in sublattice with name `s::NameType` will be selected if `region(r) && s in sublats` is
true. Any missing `region` or `sublat` will not be used to constraint the selection.

The keyword `sublats` allows the following formats:

    sublats = :A           # Onsite on sublat :A only
    sublats = (:A,)        # Same as above
    sublats = (:A, :B)     # Onsite on sublat :A and :B

# Ket algebra

`KetModel`s created with `ket` can added or substracted
together or be multiplied by scalars to build more elaborate `KetModel`s, e.g.
`ket(1) - 3 * ket(2, region = r -> norm(r) < 10)`

# Examples

```jldoctest
julia> k = ket(1, sublats=:A) - ket(1, sublats=:B)
KetModel{2}: model with 2 terms
  Normalized : false
  OnsiteTerm{Int64}:
    Sublattices      : (:A,)
    Coefficient      : 1
  OnsiteTerm{Int64}:
    Sublattices      : (:B,)
    Coefficient      : -1
```

# See also:
    `onsite`, `Vector`, `Matrix`
"""
ket(f; normalized = true, maporbitals = false, kw...) = KetModel(onsite(f; kw...), normalized, maporbitals)

Base.:*(x, k::KetModel) = KetModel(k.model * x, k.normalized, k.maporbitals)
Base.:*(k::KetModel, x) = KetModel(x * k.model, k.normalized, k.maporbitals)
Base.:-(k::KetModel) = KetModel(-k.model, k.normalized, k.maporbitals)
Base.:-(k1::KetModel, k2::KetModel) = KetModel(k1.model - k2.model, k1.normalized && k2.normalized, k1.maporbitals && k2.maporbitals)
Base.:+(k1::KetModel, k2::KetModel) = KetModel(k1.model + k2.model, k1.normalized && k2.normalized, k1.maporbitals && k2.maporbitals)

generate_amplitude(km::KetModel, term, r, M::Type{<:Number}, orbs) = toeltype(term(r, r), M, orbs)

function generate_amplitude(km::KetModel, term, r, M::Type{<:SVector}, orbs::NTuple{N}) where {N}
    if km.maporbitals
        t = toeltype(SVector(ntuple(_ -> term(r, r), Val(N))), M, orbs)
    else
        t = toeltype(term(r, r), M, orbs)
    end
    return t
end

### StochasticTraceKets ###

struct StochasticTraceKets{K<:KetModel}
    ketmodel::K
    repetitions::Int
    orthogonal::Bool
end

function Base.show(io::IO, k::StochasticTraceKets)
    ioindent = IOContext(io, :indent => "  ")
    print(io, "StochasticTraceKets:
  Repetitions  : $(k.repetitions)
  Orthogonal   : $(k.orthogonal)\n")
    show(ioindent, k.ketmodel)
end

"""
    randomkets(n, f::Function = r -> cis(2pi*rand()); orthogonal = false, maporbitals = false, kw...)

Create a `StochasticTraceKets` object to use in stochastic trace evaluation of KPM methods.
The ket amplitudes at point `r` is given by function `f(r)`. In order to produce an accurate
estimate of traces ∑⟨ket|A|ket⟩/n ≈ Tr[A] (sum over the `n` random kets), `f` must be a
random function satisfying `⟨f⟩ = 0`, `⟨ff⟩ = 0` and `⟨f'f⟩ = 1`. The default `f` produces a
uniform random phase. To apply it to an N-orbital system, `f` must in general be adapted to
produce the desired random `SVector{N}` (unless `maporbitals = true`), with the above
statistical properties for each orbital.

For example, to have independent, complex, normally-distributed random components of two
orbitals use `randomkets(n, r -> randn(SVector{2,ComplexF64}))`, or alternatively
`randomkets(n, r -> randn(ComplexF64), maporbitals = true)`.

If `orthogonal == true` the random kets are made orthogonal after sampling. This option is
currently only available for scalar ket eltype. The remaining keywords `kw` are passed to
`ket` and can be used to constrain the random amplitude to a subset of sites. `normalized`,
however, is always `false`.

# See also:
    `ket`
"""
randomkets(n::Int, f = r -> cis(2pi*rand()); orthogonal = false, kw...) =
    StochasticTraceKets(ket(f; normalized = false, kw...), n, orthogonal)
