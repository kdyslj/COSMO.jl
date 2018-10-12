using SparseArrays, LinearAlgebra, Statistics

function kktcolnorms!(P,A,normLHS,normRHS)

    colnorms!(normLHS,P,reset = true);   #start from zero
    colnorms!(normLHS,A,reset = false);  #incrementally from P norms
    rownorms!(normRHS,A)                 #same as column norms of A'
    return nothing
end

function limitScaling!(s::Vector,set::COSMO.Settings)
    @.s = clip(s,set.MIN_SCALING,set.MAX_SCALING,1.)
    return nothing
end

function limitScaling(s::Number,set::COSMO.Settings)
    s = clip(s,set.MIN_SCALING,set.MAX_SCALING,1.)
    return s
end


function scaleRuiz!(ws::COSMO.Workspace,set::COSMO.Settings)

    #references to scaling matrices from workspace
    D    = ws.sm.D
    E    = ws.sm.E
    c    = ws.sm.c[]

    #unit scaling to start
    D.diag .= 1.
    E.diag .= 1.
    c       = 1.

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

        kktcolnorms!(P,A,Dwork.diag,Ework.diag)
        limitScaling!(Dwork.diag,set)
        limitScaling!(Ework.diag,set)

        invsqrt!(Dwork.diag)
        invsqrt!(Ework.diag)

        # Scale the problem data and update the
        # equilibration matrices
        scaleData!(P,A,q,b,Dwork,Ework,1.)
        lmul!(Dwork,D)        #D[:,:] = Dtemp*D
        lmul!(Ework,E)        #D[:,:] = Dtemp*D

        # now use the Dwork array to hold the
        # column norms of the newly scaled P
        # so that we can compute the mean
        colnorms!(Dwork.diag,P)
        mean_col_norm_P = mean(Dwork.diag)
        inf_norm_q      = norm(q,Inf)

        if mean_col_norm_P  != 0. && inf_norm_q != 0.

            inf_norm_q = limitScaling(inf_norm_q,set)
            scale_cost = max(inf_norm_q,mean_col_norm_P)
            scale_cost = limitScaling(scale_cost,set)
            ctmp = 1.0 / scale_cost

            # scale the penalty terms and overall scaling
            P[:]  *= ctmp
            q    .*= ctmp
            c     *= ctmp
        end

    end #end Ruiz scaling loop

    # for certain cones we can only use a
    # a single scalar value.  In these cases
    # compute an adjustment to the overall scaling
    # so that the aggregate scaling on the cone
    # in questions turns out to be component-wise eq
    if rectifySetScalings!(E,Ework,ws.p.C)
        #only rescale if the above returns true,
        #i.e. some cone scalings were rectified
        scaleData!(P,A,q,b,I,Ework,1.)
        lmul!(Ework,E)
    end

    #scale set components
    scaleSets!(E,ws.p.C)

    #update the inverse scaling data, c and c_inv
    ws.sm.Dinv.diag .= 1. ./ D.diag
    ws.sm.Einv.diag .= 1. ./ E.diag

    #These are Base.RefValue type so that
    #scaling can remain an immutable
    ws.sm.c[]        = c
    ws.sm.cinv[]     = 1. ./ c

    # scale the potentially warm started variables
    ws.vars.x[:] = ws.sm.Dinv * ws.vars.x
    ws.vars.μ[:] = ws.sm.Einv * ws.vars.μ
    ws.vars.μ  .*= c

    return nothing
end

function invsqrt!(A::Vector{T}) where{T}
    @. A = oneunit(T) / sqrt(A)
end

function rectifySetScalings!(E,Ework,C::AbstractConvexSet)

    Ework.diag         .= 1.

    # FIX ME: split the vector Ework.diag over the sets.
    # This should NOT be done here.  Instead, the
    # splitting should happen at the time the scaling
    # structure is allocated, so that E is a Diagonal
    # of a SplitVector type.
    Es  = SplitVector(E.diag,C)
    Ews = SplitVector(Ework.diag,C)
    scale_changed = rectify_scaling!(Es,Ews,C)
    return scale_changed
end


function scaleSets!(E,C)

    # FIX ME: split the vector Ework.diag over the sets.
    # This should NOT be done here.  Instead, the
    # splitting should happen at the time the scaling
    # structure is allocated, so that E is a Diagonal
    # of a SplitVector type.
    Es = SplitVector(E.diag,C)
    scale!(C,Es)
end


function scaleData!(P,A,q,b,Ds,Es,cs=1.)

    lrmul!(Ds,P,Ds) # P[:,:] = Ds*P*Ds
    lrmul!(Es,A,Ds) # A[:,:] = Es*A*Ds
    q[:] = Ds*q
    b[:] = Es*b

    if cs != 1.
        P .*= cs
        q .*= cs
    end
    return nothing
end


function reverseScaling!(ws::COSMO.Workspace)

    cinv = ws.sm.cinv[] #from the Base.RefValue type

    ws.vars.x[:] = ws.sm.D*ws.vars.x
    ws.vars.s[:] = ws.sm.Einv*ws.vars.s
    ws.vars.μ[:] = ws.sm.E*ws.vars.μ
    ws.vars.μ  .*= cinv

    # reverse scaling for model data
    if ws.p.flags.REVERSE_SCALE_PROBLEM_DATA
        scaleData!(ws.p.P,ws.p.A,ws.p.q,ws.p.b,
        ws.sm.Dinv,ws.sm.Einv,cinv)
    end
    return nothing
end