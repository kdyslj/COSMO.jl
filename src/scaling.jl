using SparseArrays, LinearAlgebra, Statistics

function kkt_col_norms!(P::AbstractMatrix{T}, A::AbstractMatrix{T}, norm_LHS::AbstractVector{T}, norm_RHS::AbstractVector{T}) where {T <: AbstractFloat}
	col_norms!(norm_LHS, P, reset = true);   #start from zero
	col_norms!(norm_LHS, A, reset = false);  #incrementally from P norms
	row_norms!(norm_RHS, A)                 #same as column norms of A'
	return nothing
end

function limit_scaling!(s::Vector{T}, set::COSMO.Settings{T}) where {T <: AbstractFloat}
	@.s = clip(s, set.MIN_SCALING, set.MAX_SCALING, one(T))
	return nothing
end

function limit_scaling(s::T, set::COSMO.Settings{T}) where {T <: AbstractFloat}
	s = clip(s, set.MIN_SCALING, set.MAX_SCALING, one(T))
	return s
end


function scale_ruiz!(ws::COSMO.Workspace{T}) where {T <: AbstractFloat}

	set = ws.settings
	#references to scaling matrices from workspace
	D    = ws.sm.D
	E    = ws.sm.E
	c    = ws.sm.c[]

	#unit scaling to start
	D.diag .= one(T)
	E.diag .= one(T)
	c       = one(T)

	#use the inverse scalings as intermediate
	#work vectors as well, since we don't
	#compute the inverse scaling until the
	#final step
	Dwork = ws.sm.Dinv
	Ework = ws.sm.Einv

	#references to QP data matrices
	P = ws.p.P
	A = ws.p.A
	q = ws.p.q
	b = ws.p.b

	#perform scaling operations for a fixed
	#number of steps, i.e. no tolerance or
	#convergence check
	for i = 1:set.scaling

		kkt_col_norms!(P, A, Dwork.diag, Ework.diag)
		limit_scaling!(Dwork.diag, set)
		limit_scaling!(Ework.diag, set)

		inv_sqrt!(Dwork.diag)
		inv_sqrt!(Ework.diag)

		# Scale the problem data and update the
		# equilibration matrices
		scale_data!(P, A, q, b, Dwork, Ework , one(T))
		LinearAlgebra.lmul!(Dwork, D)        #D[:,:] = Dtemp*D
		LinearAlgebra.lmul!(Ework, E)        #D[:,:] = Dtemp*D

		# now use the Dwork array to hold the
		# column norms of the newly scaled P
		# so that we can compute the mean
		col_norms!(Dwork.diag, P)
		mean_col_norm_P = mean(Dwork.diag)
		inf_norm_q      = norm(q, Inf)

		if mean_col_norm_P  != 0. && inf_norm_q != 0.

			inf_norm_q = limit_scaling(inf_norm_q, set)
			scale_cost = max(inf_norm_q, mean_col_norm_P)
			scale_cost = limit_scaling(scale_cost, set)
			ctmp = one(T) / scale_cost

			# scale the penalty terms and overall scaling
			scalarmul!(P, ctmp)
			q       .*= ctmp
			c        *= ctmp
		end

	end #end Ruiz scaling loop

	# for certain cones we can only use a
	# a single scalar value.  In these cases
	# compute an adjustment to the overall scaling
	# so that the aggregate scaling on the cone
	# in questions turns out to be component-wise eq
	if rectify_set_scalings!(E, Ework, ws.p.C)
		#only rescale if the above returns true,
		#i.e. some cone scalings were rectified
		scale_data!(P, A, q, b, I, Ework, one(T))
		LinearAlgebra.lmul!(Ework, E)
	end

	issymmetric(ws.p.P) || symmetrize_full!(ws.p.P)
	#scale set components
	scale_sets!(E, ws.p.C)

	#update the inverse scaling data, c and c_inv
	ws.sm.Dinv.diag .= one(T) ./ D.diag
	ws.sm.Einv.diag .= one(T) ./ E.diag

	#These are Base.RefValue type so that
	#scaling can remain an immutable
	ws.sm.c[]        = c
	ws.sm.cinv[]     = one(T) ./ c

	# scale the potentially warm started variables
	ws.vars.x[:] = ws.sm.Dinv * ws.vars.x
	ws.vars.μ[:] = ws.sm.Einv * ws.vars.μ
	ws.vars.s.data[:] = ws.sm.E * ws.vars.s.data

	ws.vars.μ  .*= c

	return nothing
end

function inv_sqrt!(A::Vector{T}) where{T <: Real}
	@fastmath A .= one(T) ./ sqrt.(A)
end

function rectify_set_scalings!(E::AbstractMatrix{T}, Ework::AbstractMatrix{T}, C::AbstractConvexSet{T}) where {T <: AbstractFloat}

	Ework.diag         .= one(T)

	# FIX ME: split the vector Ework.diag over the sets.
	# This should NOT be done here.  Instead, the
	# splitting should happen at the time the scaling
	# structure is allocated, so that E is a Diagonal
	# of a SplitVector type.
	Es  = SplitVector(E.diag, C)
	Ews = SplitVector(Ework.diag, C)
	scale_changed = rectify_scaling!(Es, Ews, C)
	return scale_changed
end


function scale_sets!(E::AbstractMatrix{T}, C::AbstractConvexSet{T}) where {T <: AbstractFloat}

	# FIX ME: split the vector Ework.diag over the sets.
	# This should NOT be done here.  Instead, the
	# splitting should happen at the time the scaling
	# structure is allocated, so that E is a Diagonal
	# of a SplitVector type.
	Es = SplitVector(E.diag, C)
	scale!(C, Es)
end


function scale_data!(P::AbstractMatrix{T}, A::AbstractMatrix{T}, q::AbstractVector{T}, b::AbstractVector{T}, Ds::Union{IdentityMatrix, AbstractMatrix{T}}, Es::Union{IdentityMatrix, AbstractMatrix{T}}, cs::T = one(T)) where {T <: AbstractFloat}

	lrmul!(Ds, P, Ds) # P[:,:] = Ds*P*Ds
	lrmul!(Es, A, Ds) # A[:,:] = Es*A*Ds
	q[:] = Ds * q
	b[:] = Es * b      
	if cs != one(T)
		scalarmul!(P,cs)
		q .*= cs
	end
	return nothing
end

function reverse_scaling!(ws::COSMO.Workspace)

	cinv = ws.sm.cinv[] #from the Base.RefValue type
	ws.vars.x[:] = ws.sm.D * ws.vars.x
	ws.vars.s[:] = ws.sm.Einv * ws.vars.s
	ws.vars.μ[:] = ws.sm.E * ws.vars.μ
	ws.vars.μ  .*= cinv

	# reverse scaling for model data
	if ws.flags.REVERSE_SCALE_PROBLEM_DATA
		scale_data!(ws.p.P, ws.p.A, ws.p.q, ws.p.b,
			ws.sm.Dinv, ws.sm.Einv, cinv)
	end
	return nothing
end
