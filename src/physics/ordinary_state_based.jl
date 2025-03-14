"""
    OSBMaterial()
    OSBMaterial{Correction}()

A material type used to assign the material of a [`Body`](@ref) with the ordinary
state-based formulation of peridynamics.

Possible correction methods are:
- [`NoCorrection`](@ref): No correction is applied (default)
- [`EnergySurfaceCorrection`](@ref): The energy based surface correction method of
    Le and Bobaru (2018) is applied

# Examples

```julia-repl
julia> mat = OSBMaterial()
OSBMaterial{NoCorrection}()

julia> mat = OSBMaterial{EnergySurfaceCorrection}()
OSBMaterial{EnergySurfaceCorrection}()
```

---

```julia
OSBMaterial{Correction}
```

Material type for the ordinary state-based peridynamics formulation.

# Type Parameters
- `Correction`: A correction algorithm type. See the constructor docs for more informations.

# Allowed material parameters
When using [`material!`](@ref) on a [`Body`](@ref) with `OSBMaterial`, then the following
parameters are allowed:
Material parameters:
- `horizon::Float64`: Radius of point interactions
- `rho::Float64`: Density
Elastic parameters:
- `E::Float64`: Young's modulus
- `nu::Float64`: Poisson's ratio
- `G::Float64`: Shear modulus
- `K::Float64`: Bulk modulus
- `lambda::Float64`: 1st Lamé parameter
- `mu::Float64`: 2nd Lamé parameter
Fracture parameters:
- `Gc::Float64`: Critical energy release rate
- `epsilon_c::Float64`: Critical strain

!!! note "Elastic parameters"
    Note that exactly two elastic parameters are required to specify a material.
    Please choose two out of the six allowed elastic parameters.

# Allowed export fields
When specifying the `fields` keyword of [`Job`](@ref) for a [`Body`](@ref) with
`OSBMaterial`, the following fields are allowed:
- `position::Matrix{Float64}`: Position of each point
- `displacement::Matrix{Float64}`: Displacement of each point
- `velocity::Matrix{Float64}`: Velocity of each point
- `velocity_half::Matrix{Float64}`: Velocity parameter for Verlet time solver
- `acceleration::Matrix{Float64}`: Acceleration of each point
- `b_int::Matrix{Float64}`: Internal force density of each point
- `b_ext::Matrix{Float64}`: External force density of each point
- `damage::Vector{Float64}`: Damage of each point
- `n_active_bonds::Vector{Int}`: Number of intact bonds of each point
"""
struct OSBMaterial{Correction,K} <: AbstractBondSystemMaterial{Correction}
    kernel::K
    function OSBMaterial{Correction}(kernel::K) where {Correction,K}
        return new{Correction,K}(kernel)
    end
end

OSBMaterial{C}(; kernel::F=linear_kernel) where{C,F} = OSBMaterial{C}(kernel)
OSBMaterial(; kwargs...) = OSBMaterial{NoCorrection}(; kwargs...)

struct OSBPointParameters <: AbstractPointParameters
    δ::Float64
    rho::Float64
    E::Float64
    nu::Float64
    G::Float64
    K::Float64
    λ::Float64
    μ::Float64
    Gc::Float64
    εc::Float64
    bc::Float64
end

function OSBPointParameters(mat::OSBMaterial, p::Dict{Symbol,Any})
    (; δ, rho, E, nu, G, K, λ, μ) = get_required_point_parameters(mat, p)
    (; Gc, εc) = get_frac_params(p, δ, K)
    bc = 18 * K / (π * δ^4) # bond constant
    return OSBPointParameters(δ, rho, E, nu, G, K, λ, μ, Gc, εc, bc)
end

@params OSBMaterial OSBPointParameters

@storage OSBMaterial struct OSBStorage <: AbstractStorage
    @lthfield position::Matrix{Float64}
    @pointfield displacement::Matrix{Float64}
    @pointfield velocity::Matrix{Float64}
    @pointfield velocity_half::Matrix{Float64}
    @pointfield velocity_half_old::Matrix{Float64}
    @pointfield acceleration::Matrix{Float64}
    @htlfield b_int::Matrix{Float64}
    @pointfield b_int_old::Matrix{Float64}
    @pointfield b_ext::Matrix{Float64}
    @pointfield density_matrix::Matrix{Float64}
    @pointfield damage::Vector{Float64}
    bond_active::Vector{Bool}
    @pointfield n_active_bonds::Vector{Int}
end

function init_field(::OSBMaterial, ::AbstractTimeSolver, system::BondSystem, ::Val{:b_int})
    return zeros(3, get_n_points(system))
end

function force_density_point!(storage::OSBStorage, system::BondSystem, mat::OSBMaterial,
                              params::OSBPointParameters, t, Δt, i)
    wvol = calc_weighted_volume(storage, system, mat, params, i)
    iszero(wvol) && return nothing
    dil = calc_dilatation(storage, system, mat, params, wvol, i)
    c1 = 15.0 * params.G / wvol
    c2 = dil * (3.0 * params.K / wvol - c1 / 3.0)
    for bond_id in each_bond_idx(system, i)
        bond = system.bonds[bond_id]
        j, L = bond.neighbor, bond.length
        Δxij = get_vector_diff(storage.position, i, j)
        l = norm(Δxij)
        ε = (l - L) / L
        stretch_based_failure!(storage, system, bond, params, ε, i, bond_id)
        p_int = kernel(system, bond_id) * bond_failure(storage, bond_id) *
                surface_correction_factor(system.correction, bond_id) *
                (c2 * L + c1 * (l - L)) / l .* Δxij
        update_add_vector!(storage.b_int, i, p_int .* system.volume[j])
        update_add_vector!(storage.b_int, j, -p_int .* system.volume[i])
    end
    return nothing
end

function force_density_point!(storage::OSBStorage, system::BondSystem, mat::OSBMaterial,
                              paramhandler::ParameterHandler, t, Δt, i)
    params_i = get_params(paramhandler, i)
    wvol = calc_weighted_volume(storage, system, mat, params_i, i)
    iszero(wvol) && return nothing
    dil = calc_dilatation(storage, system, mat, params_i, wvol, i)
    for bond_id in each_bond_idx(system, i)
        bond = system.bonds[bond_id]
        j, L = bond.neighbor, bond.length
        Δxij = get_vector_diff(storage.position, i, j)
        l = norm(Δxij)
        ε = (l - L) / L
        stretch_based_failure!(storage, system, bond, params_i, ε, i, bond_id)
        params_j = get_params(paramhandler, j)
        c1 = 15.0 * (params_i.G + params_j.G) / (2 * wvol)
        c2 = dil * (3.0 * (params_i.K + params_j.K) / (2 * wvol) - c1 / 3.0)
        p_int = kernel(system, bond_id) * bond_failure(storage, bond_id) *
                surface_correction_factor(system.correction, bond_id) *
                (c2 * L + c1 * (l - L)) / l .* Δxij
        update_add_vector!(storage.b_int, i, p_int .* system.volume[j])
        update_add_vector!(storage.b_int, j, -p_int .* system.volume[i])
    end
    return nothing
end

function calc_weighted_volume(storage::OSBStorage, system::BondSystem, mat::OSBMaterial,
                              params::OSBPointParameters, i)
    wvol = 0.0
    for bond_id in each_bond_idx(system, i)
        bond = system.bonds[bond_id]
        j, L = bond.neighbor, bond.length
        ΔXij = get_vector_diff(system.position, i, j)
        ΔXij_sq = dot(ΔXij, ΔXij)
        scfactor = surface_correction_factor(system.correction, bond_id)
        ωij = kernel(system, bond_id) * storage.bond_active[bond_id] * scfactor
        wvol += ωij * ΔXij_sq * system.volume[j]
    end
    return wvol
end

function calc_dilatation(storage::OSBStorage, system::BondSystem, mat::OSBMaterial,
                         params::OSBPointParameters, wvol, i)
    dil = 0.0
    c1 = 3.0 / wvol
    for bond_id in each_bond_idx(system, i)
        bond = system.bonds[bond_id]
        j, L = bond.neighbor, bond.length
        Δxij = get_vector_diff(storage.position, i, j)
        l = norm(Δxij)
        scfactor = surface_correction_factor(system.correction, bond_id)
        ωij = kernel(system, bond_id) * storage.bond_active[bond_id] * scfactor
        dil += ωij * c1 * L * (l - L) * system.volume[j]
    end
    return dil
end
