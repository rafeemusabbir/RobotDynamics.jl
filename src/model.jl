# export
#     AbstractModel,
#     RigidBody,
#     dynamics,
#     discrete_dynamics,
#     jacobian!,
#     discrete_jacobian!,
# 	orientation,
# 	state_dim,
# 	control_dim,
# 	state_diff_size
#
# export
#     QuadratureRule,
# 	RK2,
#     RK3,
# 	RK4,
#     HermiteSimpson


"""
 	AbstractModel

Abstraction of a model of a dynamical system of the form ẋ = f(x,u), where x is the n-dimensional state vector
and u is the m-dimensional control vector.

Any inherited type must define the following interface:
ẋ = dynamics(model, x, u)
n,m = size(model)
"""
abstract type AbstractModel end

"""
	LieGroupModel <: AbstractModel

Abstraction of a dynamical system whose state contains at least one arbitrary rotation.
"""
abstract type LieGroupModel <: AbstractModel end


"""
	RigidBody{R<:Rotation} <: LieGroupModel

Abstraction of a dynamical system with free-body dynamics, with a 12 or 13-dimensional state
vector: `[p; q; v; ω]`
where `p` is the 3D position, `q` is the 3 or 4-dimension attitude representation, `v` is the
3D linear velocity, and `ω` is the 3D angular velocity.

# Interface
Any single-body system can leverage the `RigidBody` type by inheriting from it and defining the
following interface:
```julia
forces(::MyRigidBody, x, u)  # return the forces in the world frame
moments(::MyRigidBody, x, u) # return the moments in the body frame
inertia(::MyRigidBody, x, u) # return the 3x3 inertia matrix
mass(::MyRigidBody, x, u)  # return the mass as a real scalar
```

Instead of defining `forces` and `moments` you can define the higher-level `wrenches` function
	wrenches(model::MyRigidbody, z::AbstractKnotPoint)
	wrenches(model::MyRigidbody, x, u)

# Rotation Parameterization
A `RigidBody` model must specify the rotational representation being used. Any `Rotations.Rotation{3}`
can be used, but we suggest one of the following:
* `UnitQuaternion`
* `MRP`
* `RodriguesParam`
"""
abstract type RigidBody{R<:Rotation} <: LieGroupModel end

"Integration rule for approximating the continuous integrals for the equations of motion"
abstract type QuadratureRule end

"Specifier for continuous systems (i.e. no integration)"
abstract type Continuous <: QuadratureRule end

"Integration rules of the form x′ = f(x,u), where x′ is the next state"
abstract type Explicit <: QuadratureRule end

"Integration rules of the form x′ = f(x,u,x′,u′), where x′,u′ are the states and controls at the next time step."
abstract type Implicit <: QuadratureRule end

"Fourth-order Runge-Kutta method with zero-order-old on the controls"
abstract type RK4 <: Explicit end

"Second-order Runge-Kutta method with zero-order-old on the controls"
abstract type RK3 <: Explicit end

"Second-order Runge-Kutta method with zero-order-old on the controls (i.e. midpoint)"
abstract type RK2 <: Explicit end

abstract type Euler <: Explicit end

"Third-order Runge-Kutta method with first-order-hold on the controls"
abstract type HermiteSimpson <: Implicit end

"Default quadrature rule"
const DEFAULT_Q = RK3

abstract type DiffMethod end
struct ForwardAD <: DiffMethod end
struct FiniteDifference <: DiffMethod end
diffmethod(::AbstractModel) = ForwardAD()  # set default to ForwardDiff
function FiniteDiff.JacobianCache(
    model::AbstractModel, 
    fdtype::Union{Val{T1},Type{T1}} = Val(:forward), 
    dtype::Type{T2} = Float64;
    kwargs...) where {T1,T2} 
    n,m = size(model)
    FiniteDiff.JacobianCache(zeros(T2,n+m), zeros(T2,n), fdtype, dtype; kwargs...)
end

#=
Convenient methods for creating state and control vectors directly from the model
=#
for method in [:rand, :zeros, :ones]
    @eval begin
        function Base.$(method)(model::AbstractModel)
            n,m = size(model)
            x = @SVector $(method)(n)
            u = @SVector $(method)(m)
            return x, u
        end
        function Base.$(method)(::Type{T}, model::AbstractModel) where T
            n,m = size(model)
            x = @SVector $(method)(T,n)
            u = @SVector $(method)(T,m)
            return x,u
        end
    end
end
function Base.fill(model::AbstractModel, val::Real)
    n,m = size(model)
    x = @SVector fill(val,n)
    u = @SVector fill(val,m)
    return x, u
end

@inline control_dim(::AbstractModel) = throw(ErrorException("control_dim not implemented"))
@inline state_dim(::AbstractModel) = throw(ErrorException("state_dim not implemented"))

"""Default size method for model (assumes model has fields n and m)"""
@inline Base.size(model::AbstractModel) = state_dim(model), control_dim(model)

############################################################################################
#                               CONTINUOUS TIME METHODS                                    #
############################################################################################
"""
	ẋ = dynamics(model, z::AbstractKnotPoint)
	ẋ = dynamics(model, x, u, [t=0])

Compute the continuous dynamics of a forced dynamical given the states `x`, controls `u` and
time `t` (optional).
"""
@inline dynamics(model::AbstractModel, z::AbstractKnotPoint) = dynamics(model, state(z), control(z), z.t)

# Default to not passing in t
@inline dynamics(model::AbstractModel, x, u, t) = dynamics(model, x, u)

"""
	∇f = jacobian!(∇f, model, z::AbstractKnotPoint)

Compute the `n × (n + m)` Jacobian `∇f` of the continuous-time dynamics using ForwardDiff.
Only accepts an `AbstractKnotPoint` as input in order to avoid potential allocations
associated with concatenation.
"""
function jacobian!(∇f::AbstractMatrix, model::AbstractModel, z::AbstractKnotPoint, args...)
    _jacobian!(diffmethod(model), ∇f, model, z, args...)
end

function _jacobian!(::ForwardAD, ∇f::AbstractMatrix, model::AbstractModel, z::AbstractKnotPoint)
    ix, iu = z._x, z._u
	t = z.t
    f_aug(z) = dynamics(model, z[ix], z[iu], t)
    s = z.z
	ForwardDiff.jacobian!(get_data(∇f), f_aug, s)
end

function _jacobian!(::FiniteDifference, ∇f::AbstractMatrix, model::AbstractModel, z::AbstractKnotPoint, cache=FiniteDiff.JacobianCache(model))
    ix,iu,t = z._x, z._u, z.t
    f_aug!(ẋ,z) = copyto!(ẋ, dynamics(model, z[ix], z[iu]))
    cache.x1 .= z.z
    FiniteDiff.finite_difference_jacobian!(∇f, f_aug!, cache.x1, cache)
end

function ∇jacobian!(∇f::AbstractMatrix, model::AbstractModel, z::AbstractKnotPoint, b::AbstractVector)
    ix,iu = z._x, z._u
    t = z.t
    f_aug(z) = dynamics(model, z[ix], z[iu], t)'b
    ForwardDiff.hessian!(∇f, f_aug, z.z)
end

DynamicsJacobian(model::AbstractModel) = DynamicsJacobian(state_dim(model), control_dim(model))

############################################################################################
#                          EXPLICIT DISCRETE TIME METHODS                                  #
############################################################################################

# Set default integrator
@inline discrete_dynamics(model::AbstractModel, z::AbstractKnotPoint) =
    discrete_dynamics(DEFAULT_Q, model, z)

""" Compute the discretized dynamics of `model` using explicit integration scheme `Q<:QuadratureRule`.

Methods:
```
x′ = discrete_dynamics(model, model, z)  # uses $(DEFAULT_Q) as the default integration scheme
x′ = discrete_dynamics(Q, model, x, u, t, dt)
x′ = discrete_dynamics(Q, model, z::KnotPoint)
```

The default integration scheme is stored in `TrajectoryOptimization.DEFAULT_Q`
"""
@inline discrete_dynamics(::Type{Q}, model::AbstractModel, z::AbstractKnotPoint) where Q<:Explicit =
    discrete_dynamics(Q, model, state(z), control(z), z.t, z.dt)

@inline discrete_dynamics(::Type{Q}, model::AbstractModel, x, u, t, dt) where Q =
    integrate(Q, model, x, u, t, dt)


"""
	propagate_dynamics(::Type{Q}, model, z_, z)

Evaluate the discrete dynamics of `model` using integration method `Q` at knot point `z`,
storing the result in the states of knot point `z_`.

Useful for propagating dynamics along a trajectory of knot points.
"""
function propagate_dynamics(::Type{Q}, model::AbstractModel, z_::AbstractKnotPoint, z::AbstractKnotPoint) where Q<:Explicit
    x_next = discrete_dynamics(Q, model, z)
    set_state!(z_, x_next)
end

"""
	∇f = discrete_jacobian!(Q, ∇f, model, z::AbstractKnotPoint)

Compute the `n × (n+m)` discrete dynamics Jacobian `∇f` of `model` using explicit
integration scheme `Q<:QuadratureRule`.
"""
function discrete_jacobian!(::Type{Q}, ∇f, model::AbstractModel,
        z::AbstractKnotPoint{T,N,M}, args...) where {T,N,M,Q<:Explicit}
    _discrete_jacobian!(diffmethod(model), Q, ∇f, model, z, args...)
end

function _discrete_jacobian!(::ForwardAD, ::Type{Q}, ∇f, model::AbstractModel,
		z::AbstractKnotPoint{T,N,M}) where {T,N,M,Q<:Explicit}
    ix,iu,dt = z._x, z._u, z.dt 
    t = z.t
    fd_aug(s) = discrete_dynamics(Q, model, s[ix], s[iu], t, dt)
    ∇f .= ForwardDiff.jacobian(fd_aug, SVector{N+M}(z.z))
	return nothing
end

function _discrete_jacobian!(::FiniteDifference, ::Type{Q}, ∇f, model::AbstractModel,
		z::AbstractKnotPoint{T,N,M}, cache=FiniteDiff.JacobianCache(model)) where {T,N,M,Q<:Explicit}
    ix,iu,t,dt = z._x, z._u, z.t, z.dt
    fd_aug!(ẋ,z) = copyto!(ẋ, discrete_dynamics(Q, model, z[ix], z[iu], t, dt))
    cache.x1 .= z.z
    FiniteDiff.finite_difference_jacobian!(∇f, fd_aug!, cache.x1, cache)
end

function ∇discrete_jacobian!(::Type{Q}, ∇f::AbstractMatrix, model::AbstractModel, 
        z::AbstractKnotPoint{<:Any,n,m}, b::AbstractVector) where {Q<:Explicit,n,m}
    ix,iu = z._x, z._u
    t,dt = z.t, z.dt
    fd_aug(z) = discrete_dynamics(Q, model, z[ix], z[iu], t, dt)
    jac_z(z) = ForwardDiff.jacobian(fd_aug, z)
    ForwardDiff.hessian!(∇f, z->fd_aug(z)'b, z.z)
    ForwardDiff.jacobian(z->jac_z(z), z.z)
end

############################################################################################
#                               STATE DIFFERENTIALS                                        #
############################################################################################

state_diff(model::AbstractModel, x, x0) = x - x0
@inline state_diff_jacobian(model::AbstractModel, x::SVector{N,T}) where {N,T} = I
@inline state_diff_size(model::AbstractModel) = size(model)[1]

@inline state_diff_jacobian!(G, model::AbstractModel, z::AbstractKnotPoint) =
	state_diff_jacobian!(G, model, state(z))

function state_diff_jacobian!(G, model::AbstractModel, x::StaticVector)
	for i in 1:length(x)
		G[i,i] = 1
	end
end

# function ∇²differential!(G, model::AbstractModel, x::StaticVector, dx::AbstractVector)
# 	G .= ∇²differential(model, x, dx)
# end
