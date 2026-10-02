# flux.jl — le flux FIFO brut : fichiers .spc, fichier _acquisition.ini, et un
# flux synthétique (tests, source « simulation »).
#
# Enregistrement FIFO_150 de 32 bits (voir SPCLite.Decodeur) : macrotemps
# 12 bits (0-11), routage ou marqueurs (12-15), ADC (16-27), MARK (28),
# GAP (29), MTOV (30), INVALID (31).

const BIT_MARK = 0x10000000
const BIT_GAP = 0x20000000
const BIT_MTOV = 0x40000000
const BIT_INVALID = 0x80000000

# ---------------------------------------------------------------------
# Fichiers .spc (même format que imagerie_photons.jl)
# ---------------------------------------------------------------------

"""Fichier .spc : en-tête B&H de 4 octets (SPC_get_fifo_init_vars), puis les mots FIFO."""
function ecrire_spc(chemin::AbstractString, entete::Integer, brut::AbstractVector{UInt16})
    open(chemin, "w") do io
        write(io, htol(UInt32(entete)))
        write(io, htol.(brut))
    end
    return chemin
end

"""Relit un fichier .spc : (en-tête, mots FIFO)."""
function lire_spc(chemin::AbstractString)
    octets = read(chemin)
    length(octets) >= 4 || error("$chemin : fichier trop court")
    entete = ltoh(reinterpret(UInt32, octets[1:4])[1])
    n = (length(octets) - 4) ÷ 2
    brut = ltoh.(collect(reinterpret(UInt16, octets[5:4 + 2n])))
    return entete, brut
end

"""
    EcrivainSpc

Fichier .spc écrit au fil de l'acquisition : l'en-tête à l'ouverture, puis
chaque lecture du FIFO telle quelle. Les mots sont écrits dans l'ordre de
la machine (petit-boutiste sur x86 et ARM, comme le fichier).
"""
mutable struct EcrivainSpc
    chemin::String
    io::Union{Nothing,IOStream}
    mots::Int
end

function ouvrir_spc(chemin::AbstractString, entete::Integer)
    ENDIAN_BOM == 0x04030201 || error("écriture .spc : machine gros-boutiste non prise en charge")
    io = open(chemin, "w")
    write(io, htol(UInt32(entete)))
    return EcrivainSpc(String(chemin), io, 0)
end

function ajouter_spc!(e::EcrivainSpc, mots::Vector{UInt16}, n::Integer)
    e.io === nothing && return e
    n > 0 && write(e.io, view(mots, 1:n))
    e.mots += n
    return e
end

function fermer_spc!(e::EcrivainSpc)
    e.io === nothing || close(e.io)
    e.io = nothing
    return e.chemin
end

"""
    ecrire_acquisition_ini(chemin, m, tic_s, fenetre_ns, duree_s, deborde; geometrie, dcc)

Ce qu'il faut pour retraiter le .spc sans les cartes (section
[acquisition], relue par `retraiter`), plus la géométrie utilisée et les
réglages DCC déclarés : la trace de l'acquisition.
"""
function ecrire_acquisition_ini(chemin, m, tic_s, fenetre_ns, duree_s, deborde;
                                geometrie::Union{Nothing,Geometrie} = nothing,
                                dcc::AbstractDict = Dict{String,Any}(),
                                clamp::AbstractDict = Dict{String,Any}())
    open(chemin, "w") do io
        println(io, "; écrit par FLIMCore, relu par retraiter")
        println(io, "[acquisition]")
        println(io, "module = ", Int(m))
        println(io, "tic_s = ", Float64(tic_s))
        println(io, "fenetre_ns = ", Float64(fenetre_ns))
        println(io, "duree_s = ", Float64(duree_s))
        println(io, "fifo_deborde = ", deborde ? 1 : 0)
        if geometrie !== nothing
            println(io)
            println(io, "[geometrie]")
            for f in fieldnames(Geometrie)
                v = getfield(geometrie, f)
                println(io, f, " = ", v isa Bool ? Int(v) : v)
            end
        end
        if !isempty(clamp)
            println(io)
            println(io, "[clamp]")
            for k in sort!(collect(keys(clamp)))
                println(io, k, " = ", clamp[k])
            end
        end
        if !isempty(dcc)
            println(io)
            println(io, "[dcc]")
            println(io, "; déclarés dans config/spc.toml : le GUI ne peut pas les lire")
            for k in sort!(collect(keys(dcc)))
                println(io, k, " = ", dcc[k])
            end
        end
    end
    return chemin
end

"""
    lire_ini_textes(chemin; section) -> Dict{String,String}

Les valeurs d'une section telles qu'écrites (`lire_ini` ne garde que les
nombres) : le n° de série d'une carte, par exemple.
"""
function lire_ini_textes(chemin::AbstractString; section::AbstractString)
    d = Dict{String,String}()
    dedans = false
    for ligne in eachline(chemin)
        t = strip(first(split(ligne, ';'; limit = 2)))
        isempty(t) && continue
        if startswith(t, "[")
            dedans = lowercase(strip(t, ['[', ']', ' '])) == lowercase(section)
            continue
        end
        dedans || continue
        m = match(r"^([A-Za-z_0-9]+)\s*=\s*(.*)$", t)
        m === nothing || (d[lowercase(m.captures[1])] = String(strip(m.captures[2])))
    end
    return d
end

"""Préfixe d'une acquisition (sans extension) à partir d'un nom ou d'un chemin .spc."""
prefixe_acquisition(nom::AbstractString) = replace(String(nom), r"\.spc$"i => "")

# ---------------------------------------------------------------------
# Flux synthétique
# ---------------------------------------------------------------------

"""Générateur pseudo-aléatoire minimal (xorshift64*) : flux reproductibles sans dépendance."""
mutable struct Alea
    s::UInt64
end
Alea(graine::Integer) = Alea(UInt64(graine) * 0x9E3779B97F4A7C15 | 1)

function _suivant!(a::Alea)
    x = a.s
    x ⊻= x >> 12; x ⊻= x << 25; x ⊻= x >> 27
    a.s = x
    return x * 0x2545F4914F6CDD1D
end

"""Réel uniforme dans [0, 1)."""
_uniforme!(a::Alea) = (_suivant!(a) >> 11) * (1.0 / 9007199254740992.0)

"""
    EncodeurFifo()

Écrit des enregistrements FIFO_150 à partir de temps absolus (en tics),
avec les débordements du macrotemps : MTOV sur l'enregistrement pour un
seul tour, un enregistrement de débordements multiples au-delà.
"""
mutable struct EncodeurFifo
    base::Int64
    mots::Vector{UInt16}
end
EncodeurFifo() = EncodeurFifo(0, UInt16[])

function _pousser!(e::EncodeurFifo, w::UInt32)
    push!(e.mots, UInt16(w & 0xffff), UInt16(w >> 16))
    return e
end

function _evenement!(e::EncodeurFifo, t::Int64, bits::UInt32)
    t >= e.base || error("flux synthétique : temps décroissant ($t < $(e.base))")
    tours = (t - e.base) ÷ SPCLite.PERIODE_MT
    mtov = false
    if tours == 1
        mtov = true
        e.base += SPCLite.PERIODE_MT
    elseif tours > 1
        _pousser!(e, BIT_INVALID | BIT_MTOV | UInt32(tours))
        e.base += tours * SPCLite.PERIODE_MT
    end
    _pousser!(e, bits | UInt32(t - e.base) | (mtov ? BIT_MTOV : 0x00000000))
    return e
end

"""Photon valide au temps `t` (tics), valeur d'ADC `adc` (0-4095)."""
photon!(e::EncodeurFifo, t::Integer, adc::Integer; routage::Integer = 0, gap::Bool = false) =
    _evenement!(e, Int64(t), (UInt32(adc) << 16) | (UInt32(routage & 0xf) << 12) | (gap ? BIT_GAP : 0x00000000))

"""Marqueurs au temps `t` : `bits` = 0b0010 pour M1 (ligne), 0b0100 pour M2 (trame)."""
marqueur!(e::EncodeurFifo, t::Integer, bits::Integer) =
    _evenement!(e, Int64(t), BIT_MARK | BIT_INVALID | (UInt32(bits & 0xf) << 12))

"""
    flux_synthetique(; trames=3, lignes_par_trame=32, periode_ligne=160,
                     lignes_avant=3, photons_par_ligne=12, tau_ns=(1.5, 3.0),
                     fenetre_ns=12.5, graine=1, egalites=true, gap_toutes=0)
        -> Vector{UInt16}

Flux FIFO d'un scanner imaginaire : une ligne (M1) toutes les
`periode_ligne` tics, une trame (M2) toutes les `lignes_par_trame` lignes,
précédées de `lignes_avant` lignes hors trame. Les photons tombent au hasard
dans chaque ligne, plus nombreux au centre de l'image (un disque), avec un
déclin exponentiel de `tau_ns[1]` dans le disque et `tau_ns[2]` autour.

`egalites = true` place aussi, à chaque ligne, un photon au même tic que
le marqueur de ligne et écrit avant lui, et fait arriver chaque marqueur de
trame au même tic que la ligne 0, écrit après elle (une fois sur deux dans
le même enregistrement) : l'ordre du flux ne doit pas changer le rangement.
`gap_toutes = n` pose le bit GAP sur un photon sur n.
"""
function flux_synthetique(; trames::Integer = 3, lignes_par_trame::Integer = 32,
                          periode_ligne::Integer = 160, lignes_avant::Integer = 3,
                          photons_par_ligne::Real = 12, tau_ns = (1.5, 3.0),
                          fenetre_ns::Real = 12.5, graine::Integer = 1,
                          egalites::Bool = true, gap_toutes::Integer = 0, t0::Integer = 5000)
    a = Alea(graine)
    e = EncodeurFifo()
    dt_ns = fenetre_ns / 4096
    n_lignes = lignes_avant + trames * lignes_par_trame + 2
    compteur_gap = 0
    for l in 0:n_lignes - 1
        tl = Int64(t0) + Int64(l) * periode_ligne
        rang = l - lignes_avant                                     # ligne dans la trame
        debut_trame = rang >= 0 && rang % lignes_par_trame == 0 && rang ÷ lignes_par_trame < trames
        egalites && photon!(e, tl, 4095 - 100)                      # même tic que la ligne, avant elle
        if debut_trame && egalites && isodd(rang ÷ lignes_par_trame)
            marqueur!(e, tl, 0b0110)                                # ligne et trame dans le même mot
        else
            marqueur!(e, tl, 0b0010)
            debut_trame && marqueur!(e, tl, 0b0100)                 # trame au même tic, après la ligne
        end
        y = rang >= 0 ? (rang % lignes_par_trame) / lignes_par_trame : 0.5
        n = floor(Int, photons_par_ligne * (0.5 + _uniforme!(a)))
        temps = sort!([floor(Int64, _uniforme!(a) * periode_ligne) for _ in 1:n])
        for dt in temps
            x = dt / periode_ligne
            dans_disque = (x - 0.5)^2 + (y - 0.5)^2 < 0.09
            (dans_disque || _uniforme!(a) < 0.35) || continue
            tau = dans_disque ? tau_ns[1] : tau_ns[2]
            micro = -tau * log(1 - _uniforme!(a))
            canal = floor(Int, micro / dt_ns)
            canal < 4096 || continue
            compteur_gap += 1
            gap = gap_toutes > 0 && compteur_gap % gap_toutes == 0
            photon!(e, tl + dt, 4095 - canal; gap = gap)
        end
    end
    return e.mots
end
