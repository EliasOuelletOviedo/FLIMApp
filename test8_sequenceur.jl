include("DAQmxLite.jl")
using .DAQmxLite
using Printf

const CARTE   = "X6321"
const HORLOGE = "/$CARTE/ai/SampleClock"
const FS      = 10_000      # Hz
const T_LECT  = 0.100       # s  passe de lecture (850 nm)
const T_ACT   = 0.100       # s  passe d'actionnement (1064 nm)
const T_PAUSE = 0.020       # s  lasers éteints, galvos en déplacement
const T_IMP   = 0.001       # s  largeur des impulsions de synchro
const TOURS   = 5           # tours de spirale par passe
const RAYON   = 0.3         # V  bouclage seulement, pas des galvos réels
const CENTRES = ((-2.0, -1.0), (0.0, 1.5), (2.0, -0.5))   # V

# Port 0 : le bit k pilote la ligne P0.k. Bits 4 à 7 : numéro de région.
const B_850, B_1064, B_SEQ, B_REG = 0, 1, 2, 3
bit(b) = UInt8(1) << b
ne(t) = round(Int, t * FS)          # durée -> nombre d'échantillons

function spirale(nb, xc, yc)
    s = (0:nb-1) ./ nb
    r = RAYON .* sin.(π .* s)        # part du centre, s'ouvre, y revient
    θ = 2π * TOURS .* s
    return xc .+ r .* cos.(θ), yc .+ r .* sin.(θ)
end

function deplacement(nb, a, b)        # demi-cosinus : vitesse nulle aux deux bouts
    s = (1 .- cos.(π .* range(0, 1, length = nb))) ./ 2
    return a .+ (b - a) .* s
end

function construire()
    x, y, d, debuts = Float64[], Float64[], UInt8[], Int[]
    nl, na, np, ni = ne(T_LECT), ne(T_ACT), ne(T_PAUSE), ne(T_IMP)

    # entrée : de (0, 0) au centre de la première région, tout éteint
    append!(x, deplacement(np, 0.0, CENTRES[1][1]))
    append!(y, deplacement(np, 0.0, CENTRES[1][2]))
    append!(d, zeros(UInt8, np))

    for (k, (xc, yc)) in enumerate(CENTRES)
        code = UInt8(k - 1) << 4
        push!(debuts, length(x) + 1)

        sx, sy = spirale(nl, xc, yc)                  # passe de lecture
        append!(x, sx); append!(y, sy)
        o = fill(code | bit(B_850), nl)
        o[1:ni] .|= bit(B_REG)
        k == 1 && (o[1:ni] .|= bit(B_SEQ))
        append!(d, o)

        sx, sy = spirale(na, xc, yc)                  # passe d'actionnement
        append!(x, sx); append!(y, sy)
        append!(d, fill(code | bit(B_1064), na))

        xs, ys = k < length(CENTRES) ? CENTRES[k + 1] : (0.0, 0.0)
        append!(x, deplacement(np, xc, xs))           # pause
        append!(y, deplacement(np, yc, ys))
        append!(d, fill(code, np))
    end

    push!(x, 0.0); push!(y, 0.0); push!(d, 0x00)    # on termine à zéro
    return x, y, d, debuts, nl
end

function jouer(x, y, d)
    N = length(x)
    withtasks("ao", "do", "ai") do tao, tdo, tai
        add_ao_voltage(tao, "$CARTE/ao0:1")
        cfg_sample_clock(tao, FS; source = HORLOGE, nsamp = N)
        write_analog(tao, vcat(x, y); nsamp_per_chan = N)   # voie par voie

        add_do(tdo, "$CARTE/port0/line0:7")
        cfg_sample_clock(tdo, FS; source = HORLOGE, nsamp = N)
        write_do_u8(tdo, d)

        add_ai_voltage(tai, "$CARTE/ai0:1"; termcfg = Val_RSE)
        cfg_sample_clock(tai, FS; nsamp = N)
        @printf("Cadence retenue par la carte : %.1f Hz\n", get_samp_clk_rate(tai))

        start_task(tao); start_task(tdo)
        start_task(tai)
        m = read_analog(tai, N, 2; timeout = 10.0 + N / FS)
        wait_until_done(tao); wait_until_done(tdo)
        return m
    end
end

function meilleur_decalage(consigne, mesure)
    erreurs = [maximum(abs.(mesure[1 + o:end] .- consigne[1:end - o])) for o in 0:3]
    e, i = findmin(erreurs)
    return i - 1, e
end

x, y, d, debuts, nl = construire()
@printf("Séquence : %d échantillons, %.0f ms, %d régions\n",
        length(x), 1000 * length(x) / FS, length(CENTRES))

m = jouer(x, y, d)

o_ao, err_ao = meilleur_decalage(x, m[:, 1])
@printf("\nGalvo X (AO 0 -> AI 0) : décalage %d, erreur max %.1f mV\n", o_ao, 1000 * err_ao)

haut   = m[:, 2] .> 1.5
montes = [i for i in 2:length(haut) if haut[i] && !haut[i - 1]]
chutes = [i for i in 2:length(haut) if !haut[i] && haut[i - 1]]

println("\nPorte 850 nm (P0.0 -> AI 1)")
if length(montes) == length(debuts) == length(chutes)
    decs = vcat(montes .- debuts, chutes .- (debuts .+ nl))
    println("décalages des ", length(decs), " fronts : ", decs)
    println(all(==(o_ao), decs) && err_ao < 0.05 ?
        "Séquenceur validé : galvo et porte changent sur le même coup d'horloge." :
        "Décalages différents ou erreur galvo trop grande : voir ci-dessus.")
else
    println("Fronts inattendus : $(length(montes)) montées, $(length(chutes)) descentes, ",
            "$(length(debuts)) attendues.")
end

# Optionnel, si Plots est installé :
# using Plots
# t = (0:length(x)-1) ./ FS
# plot(t, x, label = "consigne galvo X")
# plot!(t, m[:, 1], label = "relecture AI 0")
# plot!(t, m[:, 2] ./ 2, label = "porte 850 (÷2)")
