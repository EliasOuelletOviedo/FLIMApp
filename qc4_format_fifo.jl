# qc4_format_fifo.jl — établit le format FIFO de la SPC-QC-104 et le vérifie.
#
# Pourquoi : B&H ne publie pas le format binaire des enregistrements FIFO de
# la QC-104 ; seule sa DLL sait les décoder (SPC_read_fifo rend les données
# brutes). Ce script enregistre des données brutes dans des conditions
# connues, les fait décoder par la DLL (l'arbitre), en déduit le format, puis
# le vérifie : le décodeur de SPCLite doit retrouver, sur TOUTES les données,
# chaque photon (temps, microtemps, routage, entrée) et chaque marqueur de la
# DLL. Le format n'est écrit que si la vérification passe.
#
# Il faut :
#   - SPCM fermé ; logiciel DCC ouvert, détecteurs allumés (comme d'habitude) ;
#   - le laser (SYNC branché sur l'entrée SYNC de la QC-104) ;
#   - de la lumière sur les deux détecteurs : IN1 et IN2 branchés ;
#   - reglages_qc.jl rempli (seuils, plage, décalages) ;
#   - branchements NI (tableau « Câblage » de la procédure) :
#       CTR 1 OUT (PFI 13) de la 6321 → broches 12 (Marker 0) ET 10 (Marker 3)
#       P0.4, P0.5, P0.6, P0.7       → broches 2, 3, 4, 7 (/R0 à /R3)
#       D GND                        → broche 5 ou 15
#     Jamais rien sur les broches 1, 6 et 11 (alimentations de la carte).
#
# Déroulé (environ 1 minute) : quatre acquisitions FIFO.
#   marqueurs : IN1 à IN3 coupées, marqueurs à 5 kHz, routage 0011
#   in1       : IN1 seule (avec le SYNC), routage 1001
#   in2       : IN2 seule, routage 1010
#   controle  : IN1 et IN2, marqueurs à 1 kHz, routage 0100
# Puis : décodage par la DLL, analyse des 1500 premiers enregistrements de
# chaque acquisition, déduction du format, vérification sur tout.
#
# Réussi si : « FORMAT ÉTABLI ET VÉRIFIÉ ». Le format est alors écrit dans
# format_fifo_qc104.jl, à côté de ce script ; qc5 et ton GUI l'incluent.
# Sinon : envoie-moi la sortie et le dossier resultats/qc/format (fichiers
# .spc bruts, tableaux CSV des enregistrements et du décodage de la DLL).

Base.exit_on_sigint(false)          # Ctrl+C passe par la libération des cartes
isdefined(Main, :DAQmxLite) || include("DAQmxLite.jl")
using .DAQmxLite
isdefined(Main, :SPCLite) || include("SPCLite.jl")
using .SPCLite
(isdefined(SPCLite, :VERSION_LITE) && SPCLite.VERSION_LITE >= 9) ||
    error("Julia a gardé une ancienne version de SPCLite.jl : redémarre Julia, puis relance ce script.")
using Printf, Dates
include("reglages_qc.jl")

qc4 = (
    ni_present = true,             # false : aucun signal NI (le format restera incomplet)
    carte = "X6321", compteur = "ctr1", sortie = "PFI13", lignes_routage = "port0/line4:7",
    routing_mode = 0x1900,         # M0 et M3 actifs ; M0 front montant, M3 front descendant
    bloc = 1500,                   # enregistrements analysés par acquisition
    numero_serie = "",             # "" : la première QC-104 trouvée ; sinon son n° de série
    pause_entre_acquisitions = false,  # true : le script attend Entrée avant chaque
                                   # acquisition (pour débrancher un câble à la main)
)

qc4_acquisitions = [
    (nom = "marqueurs", entrees = (false, false, false, true), code = 0b0011, freq = 5000.0, duree_s = 0.5),
    (nom = "in1",       entrees = (true, false, false, true),  code = 0b1001, freq = 0.0,    duree_s = 1.0),
    (nom = "in2",       entrees = (false, true, false, true),  code = 0b1010, freq = 0.0,    duree_s = 1.0),
    (nom = "controle",  entrees = (true, true, false, true),   code = 0b0100, freq = 1000.0, duree_s = 2.0),
]

# =====================================================================
# Acquisition
# =====================================================================

"""Paramètres de la DLL pour une acquisition : reglages_qc.jl, entrées imposées, mode FIFO."""
function parametres_qc4(r, entrees)
    p = parametres_qc(merge(REGLAGES_QC, Dict{String,Any}("entrees_actives" => entrees,
                                                          "routage_entrees" => (true, true, true))))
    merge!(p, Dict{String,Any}("mode" => 1, "adc_resolution" => 12, "stop_on_time" => 0,
                               "collect_time" => 1.0, "macro_time_clk" => 0, "trigger" => 0,
                               "routing_mode" => Int(r.routing_mode)))
    return p
end

"""Lit le FIFO pendant `duree_s` ; renvoie tous les mots de 16 bits, en nombre pair."""
function acquerir_brut_qc4(m, duree_s)
    tampon = zeros(UInt16, 1 << 21)
    tout = UInt16[]
    deborde = false
    demarrer(m)
    t0 = time()
    while time() - t0 < duree_s
        n = lire_fifo!(m, tampon)
        append!(tout, view(tampon, 1:n))
        (etat_mesure(m) & SPC_FOVFL) != 0 && (deborde = true)
        sleep(0.005)
    end
    n = lire_fifo!(m, tampon)                    # avant l'arrêt, qui vide le FIFO
    append!(tout, view(tampon, 1:n))
    arreter(m)
    isodd(length(tout)) && pop!(tout)
    return tout, deborde
end

"""Une acquisition, avec ou sans marqueurs venant du compteur de la 6321."""
function une_acquisition_qc4(r, m, a, th_routage, dossier)
    ini = ecrire_ini(joinpath(dossier, "$(a.nom).ini"), parametres_qc4(r, a.entrees))
    appliquer_ini(m, ini)
    lire_parametres(m; fichier = joinpath(dossier, "$(a.nom)_relu.ini"))
    f = fifo_init(m)
    if th_routage !== nothing
        write_do(th_routage, UInt8[(a.code >> k) & 0x01 for k in 0:3])
    end
    if r.pause_entre_acquisitions
        println("  Prêt pour « $(a.nom) » (entrées $(a.entrees)). Entrée pour lancer…")
        readline()
    end
    sleep(0.05)
    mots, deborde = if r.ni_present && a.freq > 0
        withtask("marqueurs_qc4") do th
            voie = "$(r.carte)/$(r.compteur)"
            add_co_pulse_freq(th, voie, a.freq; duty = 0.5)
            chk(ccall((:DAQmxSetCOPulseTerm, "nicaiu"), Int32,
                      (Ptr{Cvoid}, Cstring, Cstring), th, voie, "/$(r.carte)/$(r.sortie)"))
            cfg_implicit_timing(th, Val_ContSamps, 1000)
            start_task(th)
            sleep(0.02)
            acquerir_brut_qc4(m, a.duree_s)
        end
    else
        acquerir_brut_qc4(m, a.duree_s)
    end
    spc = ecrire_spc(joinpath(dossier, "$(a.nom).spc"), f.entete, mots)
    @printf("  %-9s : %9d enregistrements en %.1f s%s ; flux de type %d, mt_clock %d\n",
            a.nom, length(mots) ÷ 2, a.duree_s, deborde ? " ; FIFO DÉBORDÉ" : "", f.type_fifo, f.mt_clock)
    return (a = a, mots = mots, f = f, spc = spc, deborde = deborde)
end

# =====================================================================
# Décodage par la DLL et oracle des préfixes
# =====================================================================

flux_qc4(f) = (type_fifo = f.type_fifo, type_flux = type_flux_fichier(f.type_flux))

"""
Nombre d'entrées que la DLL tire de chacun des `B` premiers enregistrements :
on décode les préfixes de longueur 1, 2, …, B ; la différence entre deux
préfixes est la part du dernier enregistrement. Puis les entrées du bloc.
"""
function oracle_prefixes_qc4(acq, B, dossier)
    fichier = joinpath(dossier, "prefixe.spc")
    v = flux_qc4(acq.f)
    emis = zeros(Int, B)
    avant = 0
    for j in 1:B
        ecrire_spc(fichier, acq.f.entete, acq.mots, 2j)
        ent, _ = photons_dll(fichier; v..., quoi = 0x3f, max = 8j + 16)
        emis[j] = length(ent) - avant
        avant = length(ent)
        j % 250 == 0 && print("    ", acq.a.nom, " : ", j, "/", B, "\r")
    end
    print("\r", " "^40, "\r")
    ecrire_spc(fichier, acq.f.entete, acq.mots, 2B)
    bloc, _ = photons_dll(fichier; v..., quoi = 0x3f, max = 8B + 16)
    return emis, bloc
end

# =====================================================================
# Inférence du format (miroir testé en Python sur des formats simulés)
# =====================================================================

const BITS32 = 0xffffffff

champ_qc4(w::UInt32, c::Tuple{Int,Int}) =
    c[2] == 0 ? UInt32(0) : (w >> c[1]) & ((UInt32(1) << c[2]) - UInt32(1))
masque_champ_qc4(c::Tuple{Int,Int}) =
    c[2] == 0 ? UInt32(0) : (((UInt32(1) << c[2]) - UInt32(1)) << c[1])   # 32 bits : 0 - 1 = 0xffffffff
bit_qc4(w::UInt32, i::Int) = ((w >> i) & 0x00000001) == 0x00000001

"""
Pour chaque bit j de `valeurs` : le premier bit i des mots (hors `exclus`)
égal, ou complémentaire si `inverse`, sur tous les mots ; -1 si le bit j
ne varie pas ; -2 si aucun bit ne correspond.
"""
function carte_bits(mots::Vector{UInt32}, valeurs::AbstractVector, nbits::Int;
                    inverse::Bool = false, exclus::UInt32 = UInt32(0))
    res = fill(-1, nbits)
    for j in 0:nbits - 1
        vj = [((UInt64(v) >> j) & 0x1) == 0x1 for v in valeurs]
        (all(vj) || !any(vj)) && continue
        res[j + 1] = -2
        for i in 0:31
            bit_qc4(exclus, i) && continue
            if all(((bit_qc4(mots[k], i) != inverse) == vj[k]) for k in eachindex(mots))
                res[j + 1] = i
                break
            end
        end
    end
    return res
end

"""Champ contigu (décalage, largeur) déduit d'une carte de bits, ou `nothing`."""
function champ_de_carte(c::Vector{Int})
    any(==(-2), c) && return nothing
    paires = [(j - 1, i) for (j, i) in enumerate(c) if i >= 0]
    isempty(paires) && return nothing
    s = unique([i - j for (j, i) in paires])
    (length(s) == 1 && s[1] >= 0) || return nothing
    return (s[1], maximum(first, paires) + 1)
end

ajuster_champ(mots, valeurs, nbits; inverse = false) =
    isempty(mots) ? nothing : champ_de_carte(carte_bits(mots, valeurs, nbits; inverse))

"""(masque des bits constants sur tous les mots, leurs valeurs)."""
function constants_qc4(mots)
    isempty(mots) && return (UInt32(0), UInt32(0))
    et, ou = BITS32, UInt32(0)
    for w in mots
        et &= w; ou |= w
    end
    masque = ~(et ⊻ ou)
    return masque, et & masque
end

"""Un enregistrement de l'analyse : acquisition, mot de 32 bits, entrées de la DLL."""
const EnrQC4 = NamedTuple{(:nom, :w, :ent),Tuple{String,UInt32,Vector{PhotonDLL}}}

est_photon_valide(e::PhotonDLL) = !est_marqueur(e) && (e.drapeaux & DRAPEAU_INVALIDE) == 0

"""
    inferer_qc4(enrs, h_micro, decalage_mt) -> NamedTuple ou String (raison de l'échec)

`enrs` : enregistrements des blocs analysés, toutes acquisitions ; `h_micro`
: histogramme du micro_time de la DLL sur toute l'acquisition in1 ;
`decalage_mt` : mtime de la DLL divisé par 2^decalage_mt pour donner des tics.
"""
function inferer_qc4(enrs::Vector{EnrQC4}, h_micro::Vector{Int}, decalage_mt::Int)
    S = [e for e in enrs if isempty(e.ent)]
    M = [e for e in enrs if !isempty(e.ent) && all(est_marqueur, e.ent)]
    P = [e for e in enrs if length(e.ent) == 1 && !est_marqueur(e.ent[1])]
    anomalies = length(enrs) - length(S) - length(M) - length(P)
    notes = String[]
    anomalies > 0 && push!(notes, "$anomalies enregistrements à plusieurs entrées mêlant photon et marqueur")
    valides = [e for e in P if est_photon_valide(e.ent[1])]
    isempty(valides) && return "aucun photon valide décodé par la DLL"
    rv = [e.w for e in valides]
    mt(e::PhotonDLL) = e.mtime >> decalage_mt

    # 1. Microtemps : champ brut ; dll_inverse si la DLL rend son complément.
    micro = nothing
    for inv in (false, true)
        c = ajuster_champ(rv, [e.ent[1].micro for e in valides], 16; inverse = inv)
        if c !== nothing
            micro = (c, inv)
            break
        end
    end
    micro === nothing && return "microtemps introuvable"
    (s_mu, w_mu), dll_inverse = micro
    w_mu < 12 && s_mu + 12 <= 32 && (w_mu = 12)          # FIFO : toujours 4096 canaux

    # 2. Routage : les 4 bits bas de rout_chan (direct, ou complémentés par la DLL).
    routage = nothing
    rout_inverse = false
    for inv in (false, true)
        c = ajuster_champ(rv, [e.ent[1].rout & 0x000f for e in valides], 4; inverse = inv)
        if c !== nothing
            routage = (c[1], 4)
            rout_inverse = inv
            break
        end
    end
    routage === nothing &&
        return "routage introuvable : fils P0.4-P0.7 → broches 2, 3, 4, 7 branchés ? D GND → broche 5 ?"

    # 3. Macrotemps : largeurs k telles que mtime mod 2^k soit un champ contigu.
    ev = [(e.w, mt(e.ent[1])) for e in vcat(P, M)]
    carte_mt = carte_bits([w for (w, _) in ev], [t for (_, t) in ev], 32)
    candidats = Tuple{Int,Int}[]
    for k in 1:32
        c = champ_de_carte(carte_mt[1:k])
        c !== nothing && c[2] == k && c[1] + k <= 32 && push!(candidats, c)
    end
    isempty(candidats) && return "macrotemps introuvable"
    sort!(candidats; by = c -> -c[2])

    # 4. Voie : bits constants dans in1 et dans in2, de valeurs différentes, hors des champs.
    donnees = masque_champ_qc4((s_mu, w_mu)) | masque_champ_qc4(routage) | masque_champ_qc4(candidats[1])
    r1 = [e.w for e in valides if e.nom == "in1"]
    r2 = [e.w for e in valides if e.nom == "in2"]
    (isempty(r1) || isempty(r2)) && return "pas de photons dans in1 ou in2 (détecteurs, seuils, lumière ?)"
    m1, v1 = constants_qc4(r1)
    m2, v2 = constants_qc4(r2)
    cand = m1 & m2 & (v1 ⊻ v2) & ~donnees
    cand == 0 && return "aucun bit ne distingue IN1 de IN2 : les entrées se coupent-elles " *
                        "vraiment par tdc_control ? (voir pause_entre_acquisitions)"
    bits = [i for i in 0:31 if bit_qc4(cand, i)]
    s_v, l_v = bits[1], bits[end] - bits[1] + 1
    b = s_v + 1
    if l_v == 1 && b < 32 && !bit_qc4(donnees, b) && bit_qc4(m1 & m2, b) && !bit_qc4(v1, b) && !bit_qc4(v2, b)
        l_v = 2                                          # place pour IN3
    end
    voie = (s_v, l_v)
    valeurs = [Int(champ_qc4(r1[1], voie)), Int(champ_qc4(r2[1], voie)), -1, -1]
    if l_v == 2 && sort(valeurs[1:2]) == [0, 1]
        valeurs[3] = 2
        push!(notes, "valeur de IN3 déduite (2), non observée")
    end
    donnees |= masque_champ_qc4(voie)
    drapeaux = ~donnees

    # 5. Motifs, pris seulement parmi les bits hors des champs de données.
    mP, vP = constants_qc4([e.w for e in P])
    mM, vM = constants_qc4([e.w for e in M])
    mS, vS = constants_qc4([e.w for e in S])
    if !isempty(M)
        sep = mM & mP & (vM ⊻ vP) & drapeaux
        sep == 0 && return "rien ne distingue les marqueurs des photons"
        masque_marq, val_marq = sep, vM & sep
        masque_phot, val_phot = sep, vP & sep
    else
        return "aucun marqueur décodé par la DLL : câble de CTR 1 OUT vers les broches 12 et 10, " *
               "masse, ou routing_mode sans effet sur la QC-104"
    end
    if !isempty(S)
        sepP = mS & mP & (vS ⊻ vP) & drapeaux
        sepM = mS & mM & (vS ⊻ vM) & drapeaux
        (sepP == 0 || sepM == 0) && return "rien ne distingue les enregistrements de débordement"
        masque_deb = sepP | sepM
        val_deb = vS & masque_deb
    else
        masque_deb = val_deb = UInt32(0)
    end

    # 6. Débordements : la plus grande largeur du macrotemps qui explique tous les écarts.
    choix = nothing
    for macro_c in candidats
        res = analyser_debordements_qc4(enrs, macro_c, masque_deb, val_deb, decalage_mt)
        if res !== nothing
            choix = (macro_c, res)
            break
        end
    end
    choix === nothing && return "débordements du macrotemps incohérents pour toutes les largeurs essayées"
    macro_c, (bit_mtov, compte) = choix
    exclus = masque_champ_qc4(macro_c) | masque_deb | masque_marq |
             (bit_mtov >= 0 ? (UInt32(1) << bit_mtov) : UInt32(0))

    # 7. Photons invalides (si la DLL en a signalé).
    invs = [(e.ent[1].drapeaux & DRAPEAU_INVALIDE) != 0 for e in P]
    bit_inv = -1
    if any(invs) && !all(invs)
        c = carte_bits([e.w for e in P], invs, 1; exclus)
        c[1] < 0 && return "bit des photons invalides introuvable"
        bit_inv = c[1]
    end

    # 8. Marqueurs.
    bits_m = [-1, -1, -1, -1]
    for k in 1:4
        pres = [any(x -> (x.drapeaux & DRAPEAUX_MARQUEURS[k]) != 0, e.ent) for e in M]
        if any(pres) && !all(pres)
            c = carte_bits([e.w for e in M], pres, 1; exclus)
            c[1] < 0 && return "bit du marqueur M$(k - 1) introuvable"
            bits_m[k] = c[1]
        elseif any(pres)
            push!(notes, "M$(k - 1) présent dans tous les marqueurs : bit non déterminé")
        end
    end
    (bits_m[1] >= 0 && bits_m[4] >= 0) ||
        return "M0 ou M3 jamais reçu : il faut CTR 1 OUT sur les broches 12 ET 10"
    deduits = Int[]
    if bits_m[4] == bits_m[1] + 3
        for k in (2, 3)
            if bits_m[k] < 0
                bits_m[k] = bits_m[1] + k - 1
                push!(deduits, k - 1)
            end
        end
    end
    isempty(deduits) || push!(notes, "M" * join(deduits, ", M") * " déduits de M0 et M3 (non observés)")

    # 9. Sens du temps : la montée du déclin est raide, la queue lente.
    taille = max(1, length(h_micro) ÷ 64)
    g = [sum(view(h_micro, i:min(i + taille - 1, length(h_micro)))) for i in 1:taille:length(h_micro)]
    d = [g[mod1(i + 1, length(g))] - g[i] for i in eachindex(g)]
    monte, descend = maximum(d), -minimum(d)
    dll_arriere = if monte > 2 * descend
        false
    elseif descend > 2 * monte
        true
    else
        push!(notes, "sens du temps indéterminé (peu de photons ?) : supposé croissant, comme le dit le manuel")
        false
    end
    micro_inverse = dll_inverse != dll_arriere
    bit_inv < 0 && push!(notes, "aucun photon invalide observé : bit_invalide inconnu")
    push!(notes, "bit de perte (FIFO plein) non observé : les pertes se lisent par SPC_FOVFL")

    fmt = FormatFIFO(nom = "SPC-QC-104 (FIFO, format établi par qc4)",
                     macrotemps = macro_c, microtemps = (s_mu, w_mu), micro_inverse = micro_inverse,
                     routage = routage, voie = voie, valeurs_voie = Tuple(valeurs),
                     bit_invalide = bit_inv, bit_mtov = bit_mtov, bit_perte = -1,
                     masque_debord = masque_deb, valeur_debord = val_deb, compte = compte,
                     masque_marqueur = masque_marq, valeur_marqueur = val_marq,
                     bits_marqueurs = Tuple(bits_m),
                     masque_photon = masque_phot, valeur_photon = val_phot)
    return (format = fmt, dll_inverse = dll_inverse, dll_arriere = dll_arriere,
            rout_inverse = rout_inverse, notes = notes, anomalies = anomalies)
end

"""(bit_mtov, compte) qui expliquent les écarts de mtime entre événements, ou `nothing`."""
function analyser_debordements_qc4(enrs::Vector{EnrQC4}, macro_c, masque_deb, val_deb, decalage_mt)
    periode = Int64(1) << macro_c[2]
    sans = Tuple{UInt32,Int64}[]
    avec = Tuple{UInt32,Vector{UInt32},Int64}[]
    for nom in unique(e.nom for e in enrs)
        prec = nothing
        silence = UInt32[]
        for e in enrs
            e.nom == nom || continue
            if isempty(e.ent)
                push!(silence, e.w)
                continue
            end
            base = Int64(e.ent[1].mtime >> decalage_mt) - Int64(champ_qc4(e.w, macro_c))
            if prec !== nothing
                d = base - prec
                (d < 0 || d % periode != 0) && return nothing
                n = d ÷ periode
                isempty(silence) ? push!(sans, (e.w, n)) : push!(avec, (e.w, copy(silence), n))
            end
            prec = base
            empty!(silence)
        end
    end
    any(x -> x[2] > 1, sans) && return nothing
    bit_mtov = -1
    if any(x -> x[2] > 0, sans)
        c = carte_bits([x[1] for x in sans], [x[2] for x in sans], 1; exclus = masque_champ_qc4(macro_c))
        c[1] < 0 && return nothing
        bit_mtov = c[1]
    end
    mtov(w) = bit_mtov >= 0 && bit_qc4(w, bit_mtov) ? 1 : 0
    any(x -> any(s -> (s & masque_deb) != val_deb, x[2]), avec) && return nothing
    isempty(avec) && return (bit_mtov, (0, 0))
    # H1 : un débordement par enregistrement silencieux.
    all(x -> x[3] - mtov(x[1]) == length(x[2]), avec) && return (bit_mtov, (0, 0))
    # H2 : un compte dans un champ contigu des enregistrements silencieux, hors du motif ;
    # parmi les champs qui expliquent tout, le plus large (les grands comptes sont rares).
    meilleur = nothing
    for s in 0:31
        for l in 1:(32 - s)
            (masque_champ_qc4((s, l)) & masque_deb) != 0 && break    # sort de la boucle sur l seulement
            if all(x -> x[3] - mtov(x[1]) == sum(Int64(champ_qc4(w, (s, l))) for w in x[2]), avec)
                (meilleur === nothing || l > meilleur[2]) && (meilleur = (s, l))
            end
        end
    end
    meilleur === nothing && return nothing
    return (bit_mtov, meilleur)
end

# =====================================================================
# Vérification : le décodeur de SPCLite contre la DLL, sur tout
# =====================================================================

function verifier_qc4(fmt::FormatFIFO, mots::Vector{UInt16}, ent::Vector{PhotonDLL}, voies_attendues,
                      inf, decalage_mt::Int)
    d = DecodeurFIFO(fmt; garder_photons = true)
    decoder!(d, mots, length(mots))
    ph = [e for e in ent if est_photon_valide(e)]
    nrej = count(e -> !est_marqueur(e) && (e.drapeaux & DRAPEAU_INVALIDE) != 0, ent)
    length(ph) == d.photons || return "photons : $(d.photons) décodés, $(length(ph)) pour la DLL"
    d.inattendus == 0 || return "$(d.inattendus) enregistrements inattendus"
    fmt.bit_invalide >= 0 && nrej != d.rejetes && return "photons rejetés : $(d.rejetes) contre $nrej"
    # Origine commune : la première entrée de la DLL qui est un photon valide ou un marqueur.
    iref = findfirst(e -> est_photon_valide(e) || est_marqueur(e), ent)
    iref === nothing && return nothing
    ref = ent[iref]
    t0d = Int64(ref.mtime >> decalage_mt)
    t0 = if est_marqueur(ref)
        k = findfirst(k -> (ref.drapeaux & DRAPEAUX_MARQUEURS[k]) != 0, 1:4)
        isempty(d.marqueurs[k]) && return "le premier marqueur de la DLL (M$(k - 1)) n'est pas décodé"
        d.marqueurs[k][1]
    else
        isempty(d.t_photons) && return "le premier photon de la DLL n'est pas décodé"
        d.t_photons[1]
    end
    nm = 1 << fmt.microtemps[2]
    for (i, e) in enumerate(ph)
        micro = inf.dll_arriere ? nm - 1 - Int(e.micro) : Int(e.micro)
        rout = Int(e.rout & 0x000f)
        inf.rout_inverse && (rout = 15 - rout)
        t = Int64(e.mtime >> decalage_mt) - t0d
        if d.t_photons[i] - t0 != t || Int(d.micro_photons[i]) != micro || Int(d.routage_photons[i]) != rout
            return @sprintf("photon %d : décodé (t %d, micro %d, routage %d), DLL (t %d, micro %d, routage %d)",
                            i, d.t_photons[i] - t0, d.micro_photons[i], d.routage_photons[i], t, micro, rout)
        end
        if voies_attendues !== nothing && !(Int(d.voie_photons[i]) in voies_attendues)
            return "photon $i : entrée IN$(d.voie_photons[i]), attendu $(collect(voies_attendues))"
        end
    end
    for k in 1:4
        dk = [Int64(e.mtime >> decalage_mt) - t0d for e in ent if (e.drapeaux & DRAPEAUX_MARQUEURS[k]) != 0]
        nk = [t - t0 for t in d.marqueurs[k]]
        if dk != nk
            i = findfirst(j -> j > length(nk) || j > length(dk) || nk[j] != dk[j], 1:max(length(nk), length(dk)))
            return "marqueurs M$(k - 1) : $(length(nk)) décodés, $(length(dk)) pour la DLL (premier écart n° $i)"
        end
    end
    return nothing
end

# =====================================================================
# Diagnostic : empreinte des bits et tableaux CSV
# =====================================================================

"""32 caractères, bit 31 à gauche : 0 ou 1 si le bit est constant, · s'il varie, espace si vide."""
function empreinte(mots)
    isempty(mots) && return " "^32
    m, v = constants_qc4(mots)
    return join((bit_qc4(m, i) ? (bit_qc4(v, i) ? '1' : '0') : '·') for i in 31:-1:0)
end

function ecrire_bloc_csv(chemin, enrs)
    open(chemin, "w") do io
        println(io, "indice,mot_hex,entrees,mtime,micro,rout,drapeaux_hex,octets_photinfo")
        for (j, e) in enumerate(enrs)
            if isempty(e.ent)
                @printf(io, "%d,%08x,0,,,,,\n", j, e.w)
            end
            for x in e.ent
                @printf(io, "%d,%08x,%d,%d,%d,%d,%04x,%s\n", j, e.w, length(e.ent), x.mtime, x.micro,
                        x.rout, x.drapeaux, join((string(b; base = 16, pad = 2) for b in x.octets)))
            end
        end
    end
end

# =====================================================================
# Programme
# =====================================================================

function test_qc4(r)
    dossier = joinpath(@__DIR__, "resultats", "qc", "format")
    mkpath(dossier)
    ini = ecrire_ini(joinpath(dossier, "init.ini"), parametres_qc4(r, qc4_acquisitions[1].entrees))
    println("DLL : ", DLL_SPCM)

    avec_spc_tous(ini; types = (TYPE_QC104,)) do modules
        # La QC-104 voulue
        m = modules[1]
        series = Dict(k => (try eeprom(k).serie catch; "?" end) for k in modules)
        if !isempty(r.numero_serie)
            i = findfirst(k -> series[k] == r.numero_serie, modules)
            i === nothing && error("aucune QC-104 de n° de série $(r.numero_serie) (vues : $(collect(values(series))))")
            m = modules[i]
        end
        println("SPC-QC-104 : module $m, n° de série $(series[m])")

        # 1. Acquisitions
        println("\nAcquisitions :")
        acqs = if r.ni_present
            withtask("routage_qc4") do th
                add_do(th, "$(r.carte)/$(r.lignes_routage)")
                res = [une_acquisition_qc4(r, m, a, th, dossier) for a in qc4_acquisitions]
                write_do(th, UInt8[0, 0, 0, 0])
                res
            end
        else
            [une_acquisition_qc4(r, m, a, nothing, dossier) for a in qc4_acquisitions]
        end
        any(a -> a.deborde, acqs) && println("  ATTENTION : FIFO débordé, des données manquent ; baisse la lumière.")
        types_fifo = unique(a.f.type_fifo for a in acqs)
        types_fifo == [11] || println("  NOTE : flux de type $(types_fifo) (11 = FIFO_TDC attendu pour la QC-104)")

        # 2. Décodage complet par la DLL
        println("\nDécodage par la DLL (arbitre) :")
        dll = Dict{String,Vector{PhotonDLL}}()
        for a in acqs
            ent, code = photons_dll(a.spc; flux_qc4(a.f)..., quoi = 0x3f, max = 20_000_000)
            dll[a.a.nom] = ent
            nval = count(est_photon_valide, ent)
            ninv = count(e -> !est_marqueur(e) && (e.drapeaux & DRAPEAU_INVALIDE) != 0, ent)
            nm = [count(e -> (e.drapeaux & DRAPEAUX_MARQUEURS[k]) != 0, ent) for k in 1:4]
            drap = sort!(unique(e.drapeaux for e in ent))
            @printf("  %-9s : %8d photons valides, %d invalides, marqueurs M0-M3 %s ; drapeaux vus %s ; fin %d\n",
                    a.a.nom, nval, ninv, string(nm), join((string(x; base = 16) for x in first(drap, 8)), " "), code)
        end
        if all(isempty(dll[a.a.nom]) for a in acqs)
            println("\nÉCHEC : la DLL ne décode rien. Envoie-moi cette sortie et le dossier ", dossier)
            return false
        end

        # Unité du mtime de la DLL : des bits bas toujours nuls trahissent un facteur 2^p.
        tous_mt = UInt64[e.mtime for a in acqs for e in dll[a.a.nom]]
        decalage_mt = isempty(tous_mt) ? 0 : min(32, minimum(trailing_zeros(t) for t in tous_mt if t != 0; init = 64))
        decalage_mt = decalage_mt >= 32 ? 0 : decalage_mt
        decalage_mt > 0 && println("  mtime de la DLL toujours multiple de 2^$decalage_mt : divisé avant l'analyse")

        # Durée du tic, d'après les marqueurs de période connue (horloge de la 6321).
        for a in acqs
            a.a.freq > 0 || continue
            t = [Int64(e.mtime >> decalage_mt) for e in dll[a.a.nom] if (e.drapeaux & DRAPEAUX_MARQUEURS[1]) != 0]
            length(t) >= 3 || continue
            dt = (t[end] - t[1]) / (length(t) - 1)
            tic = 1 / a.a.freq / dt
            @printf("  %-9s : M0 tous les %.1f tics → tic de %.4f ns (2,048 ns attendu, écart %+.2f %%)\n",
                    a.a.nom, dt, tic * 1e9, (tic / 2.048e-9 - 1) * 100)
        end

        # 3. Oracle des préfixes
        println("\nOracle des préfixes ($(r.bloc) enregistrements par acquisition) :")
        blocs = Dict{String,Tuple{Vector{Int},Vector{PhotonDLL}}}()
        for a in acqs
            B = min(r.bloc, length(a.mots) ÷ 2)
            B == 0 && continue
            emis, bloc = oracle_prefixes_qc4(a, B, dossier)
            if any(<(0), emis) || sum(emis) != length(bloc)
                println("\nÉCHEC : la DLL ne rend pas les entrées enregistrement par enregistrement ",
                        "(elle attend la suite). Envoie-moi cette sortie et le dossier ", dossier)
                return false
            end
            blocs[a.a.nom] = (emis, bloc)
            @printf("  %-9s : %d enregistrements, %d entrées (%d silencieux)\n",
                    a.a.nom, B, length(bloc), count(==(0), emis))
        end

        # Histogramme du micro_time de la DLL sur toute l'acquisition in1 (sens du temps)
        h_micro = zeros(Int, 1 << 16)
        for e in dll["in1"]
            est_photon_valide(e) && (h_micro[Int(e.micro) + 1] += 1)
        end
        dernier = findlast(>(0), h_micro)
        h_micro = h_micro[1:(dernier === nothing ? 4096 : max(4096, nextpow(2, dernier)))]

        # 4. Inférence, dans les deux ordres de mots possibles, puis vérification sur tout
        resultat = nothing
        raisons = String[]
        for inverse in (false, true)
            enrs = EnrQC4[]
            for a in acqs
                haskey(blocs, a.a.nom) || continue
                emis, bloc = blocs[a.a.nom]
                pos = 0
                for j in eachindex(emis)
                    lo, hi = a.mots[2j - 1], a.mots[2j]
                    w = inverse ? (UInt32(lo) << 16) | UInt32(hi) : UInt32(lo) | (UInt32(hi) << 16)
                    push!(enrs, (nom = a.a.nom, w = w, ent = bloc[pos + 1:pos + emis[j]]))
                    pos += emis[j]
                end
            end
            if !inverse
                println("\nEmpreinte des enregistrements (bit 31 à gauche ; 0/1 constant, · variable) :")
                for a in acqs
                    for (cl, f) in (("photons", e -> length(e.ent) == 1 && !est_marqueur(e.ent[1])),
                                    ("marqueurs", e -> !isempty(e.ent) && all(est_marqueur, e.ent)),
                                    ("silencieux", e -> isempty(e.ent)))
                        mots = [e.w for e in enrs if e.nom == a.a.nom && f(e)]
                        isempty(mots) && continue
                        @printf("  %-9s %-10s %6d  %s\n", a.a.nom, cl, length(mots), empreinte(mots))
                    end
                    ecrire_bloc_csv(joinpath(dossier, "bloc_$(a.a.nom).csv"), [e for e in enrs if e.nom == a.a.nom])
                end
            end
            inf = inferer_qc4(enrs, h_micro, decalage_mt)
            if inf isa String
                push!(raisons, "ordre $(inverse ? "poids fort d'abord" : "poids faible d'abord") : $inf")
                continue
            end
            fmt = inverse ? copie_format(inf.format; mots_inverses = true) : inf.format
            attendues = Dict("marqueurs" => nothing, "in1" => (1,), "in2" => (2,), "controle" => (1, 2))
            echec = nothing
            for a in acqs
                v = verifier_qc4(fmt, a.mots, dll[a.a.nom], attendues[a.a.nom], inf, decalage_mt)
                if v !== nothing
                    echec = "$(a.a.nom) : $v"
                    break
                end
            end
            if echec === nothing
                resultat = (format = fmt, inf = inf)
                break
            end
            push!(raisons, "ordre $(inverse ? "poids fort d'abord" : "poids faible d'abord") : format déduit, " *
                           "mais vérification refusée, $echec")
        end

        println()
        if resultat === nothing
            println("ÉCHEC : format non établi.")
            foreach(x -> println("  ", x), raisons)
            println("Envoie-moi cette sortie et le dossier ", dossier, " : les fichiers .spc et bloc_*.csv ",
                    "suffisent pour finir l'analyse à la main.")
            return false
        end

        f = resultat.format
        nph = sum(count(est_photon_valide, dll[a.a.nom]) for a in acqs)
        nmq = sum(count(est_marqueur, dll[a.a.nom]) for a in acqs)
        verif = "vérifié le $(Dates.format(now(), "yyyy-mm-dd HH:MM")) sur la QC-104 n° $(series[m]) : " *
                "$nph photons et $nmq marqueurs identiques à la DLL ($(basename(DLL_SPCM)))"
        f = copie_format(f; verification = verif)
        println("FORMAT ÉTABLI ET VÉRIFIÉ ($verif)")
        @printf("  ordre des mots     : %s\n", f.mots_inverses ? "poids fort d'abord" : "poids faible d'abord")
        @printf("  macrotemps         : bits %d à %d (%d bits)\n", f.macrotemps[1], sum(f.macrotemps) - 1, f.macrotemps[2])
        @printf("  microtemps         : bits %d à %d, %s\n", f.microtemps[1], sum(f.microtemps) - 1,
                f.micro_inverse ? "inversé (temps croissant = complément)" : "temps croissant direct")
        @printf("  routage            : bits %d à %d%s\n", f.routage[1], sum(f.routage) - 1,
                resultat.inf.rout_inverse ? " (la DLL en rend le complément)" : "")
        @printf("  entrée (voie)      : bits %d à %d ; valeurs IN1..IN4 %s\n", f.voie[1], sum(f.voie) - 1,
                string(f.valeurs_voie))
        @printf("  marqueurs          : motif 0x%08x = 0x%08x ; bits M0..M3 %s\n", f.masque_marqueur,
                f.valeur_marqueur, string(f.bits_marqueurs))
        @printf("  débordements       : %s ; MTOV bit %d\n",
                f.masque_debord == 0 ? "aucun enregistrement dédié" :
                @sprintf("motif 0x%08x = 0x%08x, compte %s", f.masque_debord, f.valeur_debord,
                         f.compte[2] == 0 ? "1 par enregistrement" : "bits $(f.compte[1]) à $(sum(f.compte) - 1)"),
                f.bit_mtov)
        @printf("  photon invalide    : bit %d\n", f.bit_invalide)
        for n in resultat.inf.notes
            println("  note : ", n)
        end
        commentaire = "SPC-QC-104 n° $(series[m]), DLL $(DLL_SPCM)\n" * join(resultat.inf.notes, "\n")
        chemin = ecrire_format(joinpath(@__DIR__, "format_fifo_qc104.jl"), f; commentaire)
        println("\nÉcrit : ", chemin)
        println("Suite : qc5_photons.jl. Colle cette sortie dans la conversation.")
        return true
    end
end

test_qc4(qc4)
