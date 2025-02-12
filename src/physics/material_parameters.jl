@inline elasticity_parameters() = (:E, :nu, :G, :K, :λ, :μ)

@inline elasticity_kwargs() = (:E, :nu)
@inline discretization_kwargs() = (:horizon, :rho)

"""
    material!(body, set_name; kwargs...)
    material!(body; kwargs...)

Assign material point parameters to points of `body`. If no `set_name` is specified, then
the parameters will be set for all points of the body.

# Arguments

- `body::AbstractBody`: [`Body`](@ref).
- `set_name::Symbol`: The name of a point set of this body.

# Keywords

Allowed keywords depend on the selected material model. Please look at the documentation
of the material you specified when creating the body.
The default material keywords are:

- `horizon::Float64`: Radius of point interactions
- `rho::Float64`: Density
- `E::Float64`: Young's modulus
- `nu::Float64`: Poisson's ratio
- `Gc::Float64`: Critical energy release rate
- `epsilon_c::Float64`: Critical strain

!!! note "Fracture parameters"
    To enable fracture in a simulation, define one of the allowed fracture parameters.
    If none are defined, fracture is disabled.

!!! danger "Overwriting failure permission with `material!` and `failure_permit!`"
    The function `material!` calls `failure_permit!` to enable or disable failure.
    If `failure_permit!` is called in particular,
    previously set failure permissions might be overwritten!

# Throws

- Errors if a kwarg is not eligible for specification with the body material.

# Example

```julia-repl
julia> material!(body; horizon=3.0, E=2.1e5, rho=8e-6, Gc=2.7)

julia> body
1000-point Body{BBMaterial{NoCorrection}}:
  1 point set(s):
    1000-point set `all_points`
  1 point parameter(s):
    Parameters BBMaterial: δ=3.0, E=210000.0, nu=0.25, rho=8.0e-6, Gc=2.7
```
"""
function material! end

function material!(body::AbstractBody, set_name::Symbol; kwargs...)
    check_if_set_is_defined(body.point_sets, set_name)

    p = Dict{Symbol,Any}(kwargs)
    check_material_kwargs(body.mat, p)

    points = body.point_sets[set_name]
    params = get_point_params(body.mat, p)

    _material!(body, points, params)
    set_failure_permissions!(body, set_name, params)

    return nothing
end

function material!(body::AbstractBody; kwargs...)
    isempty(body.point_params) || empty!(body.point_params)

    material!(body, :all_points; kwargs...)

    return nothing
end

function _material!(b::AbstractBody, points::V, params::P) where {P,V}
    push!(b.point_params, params)
    id = length(b.point_params)
    b.params_map[points] .= id
    return nothing
end

function check_material_kwargs(mat::AbstractMaterial, p::Dict{Symbol,Any})
    allowed_kwargs = allowed_material_kwargs(mat)
    check_kwargs(p, allowed_kwargs)
    return nothing
end

function get_horizon(p::Dict{Symbol,Any})
    if !haskey(p, :horizon)
        throw(UndefKeywordError(:horizon))
    end
    δ::Float64 = float(p[:horizon])
    δ ≤ 0 && throw(ArgumentError("`horizon` should be larger than zero!\n"))
    return (; δ,)
end

function get_density(p::Dict{Symbol,Any})
    if !haskey(p, :rho)
        throw(UndefKeywordError(:rho))
    end
    rho::Float64 = float(p[:rho])
    rho ≤ 0 && throw(ArgumentError("`rho` should be larger than zero!\n"))
    return (; rho,)
end

function get_elastic_params(p::Dict{Symbol,Any})
    if !haskey(p, :E) || !haskey(p, :nu)
        msg = "insufficient keywords for calculation of elastic parameters!\n"
        msg *= "The keywords `E` (elastic modulus) and `nu` (poisson ratio) are needed!\n"
        throw(ArgumentError(msg))
    end
    E::Float64 = float(p[:E])
    E ≤ 0 && throw(ArgumentError("`E` should be larger than zero!\n"))
    nu::Float64 = float(p[:nu])
    nu ≤ 0 && throw(ArgumentError("`nu` should be larger than zero!\n"))
    nu ≥ 1 && throw(ArgumentError("too high value of `nu`! Condition: 0 < `nu` ≤ 1\n"))
    G = E / (2 * (1 + nu))
    K = E / (3 * (1 - 2 * nu))
    λ = E * nu / ((1 + nu) * (1 - 2nu))
    μ = G
    return (; E, nu, G, K, λ, μ)
end

function log_material_parameters(param::AbstractPointParameters; indentation::Int=2)
    msg = msg_qty("horizon", param.δ; indentation=indentation)
    msg *= msg_qty("density", param.rho; indentation=indentation)
    msg *= msg_qty("Young's modulus", param.E; indentation=indentation)
    msg *= msg_qty("Poisson's ratio", param.nu; indentation=indentation)
    msg *= msg_qty("shear modulus", param.G; indentation=indentation)
    msg *= msg_qty("bulk modulus", param.K; indentation=indentation)
    return msg
end

function Base.show(io::IO, @nospecialize(params::AbstractPointParameters))
    print(io, "Parameters ", material_type(params), ": ")
    print(io, msg_fields_inline(params, (:δ, :E, :nu, :rho, :Gc)))
    return nothing
end

function Base.show(io::IO, ::MIME"text/plain",
                   @nospecialize(params::AbstractPointParameters))
    if get(io, :compact, false)
        show(io, params)
    else
        println(io, typeof(params), ":")
        print(io, msg_fields(params))
    end
    return nothing
end
