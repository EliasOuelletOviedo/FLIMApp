# passes.jl — les passes du mode Realtime dans le flux FIFO.
#
# Une passe est un scan d'une ROI (un créneau de la NI). Le signal de passe,
# haut pendant le scan, vient d'un compteur de la 6321 cadencé par l'horloge
# de l'AO (PFI13 = CTR 1 OUT). Il arrive sur M0 de chaque carte, actif sur
# le front montant : le début de la passe ; sa fin est le M0 plus la durée
# programmée du scan (`[clamp] fin_par_m3 = false`, le défaut), ou le front
# descendant du même signal sur M3 (`fin_par_m3 = true`, M3 câblé aussi).
# La carte horodate ces fronts avec les photons : la passe est délimitée par
# la carte elle-même, sans échéance logicielle. Un retard du moteur ne fait
# que remplir le FIFO ; s'il déborde, la carte le signale (SPC_FOVFL) et les
# enregistrements GAP marquent l'endroit de la perte.
#
# Chaque photon d'une passe va dans le déclin de son code de routage : la
# valeur que la carte lit sur /R0–/R3, que la NI tient pendant le scan.
# Pendant les déplacements des galvos et les pauses, la NI écrit le code
# réservé (`CODE_HORS_ROI`) : ces photons-là sont jetés.

const MARQUEUR_DEBUT = 1     # M0 : bit 0 des marqueurs
const MARQUEUR_FIN = 4       # M3 : bit 3

"""
    Passes(; canaux=256, duree=0, periode=0, tolerance=0)

Découpe un flux FIFO en passes, au fil des lectures (`passes!`). Une passe
commence à un M0 ; elle finit au M3 suivant (`duree = 0`), ou `duree` tics
après son M0 (`duree > 0` : M0 seul, la passe dure le scan programmé ; les
M3 sont ignorés).

M0 seul, avec `periode > 0` (le créneau scan + pause, en tics) : chaque M0
doit tomber un nombre entier `n` de créneaux après le dernier M0 valide, à
`n × tolerance` tics près. `n > 1` : `n − 1` M0 perdus (`m0_manquants`,
autant de passes perdues). Hors cadence, le M0 est un parasite
(`m0_hors_cadence`) : ignoré, la passe en cours continue. Deux M0 à un
créneau l'un de l'autre hors de l'ancienne cadence la remplacent (le
signal de passe a redémarré).

Pendant la passe, chaque photon va dans `histo[canal, code + 1]`
(`canaux` canaux de temps croissant, 16 codes de routage). À chaque fin de
passe, `f(p, t_debut, t_fin, pertes)` (temps en tics, `pertes` : GAP
décodés depuis la passe précédente), puis l'histogramme repart de zéro. `intervalle` : tics entre les deux derniers
M0 (-1 avant le deuxième).

À temps égal, une fin passe avant un début, et un début avant un photon :
un photon pile sur M0 est dans la passe, pile sur sa fin il n'y est plus.
Les événements du dernier tic lu attendent la lecture suivante.

Les photons du code réservé (`CODE_HORS_ROI` : déplacements, pauses) sont
jetés et comptés dans `hors_roi` ; les autres photons hors passe (décalage
d'un échantillon entre le code et le signal de passe) dans `hors_passe` —
sauf ceux d'avant la première passe et d'après la dernière (la NI ne
pilote pas encore, ou plus, les lignes de routage), dans `hors_bords`.
Un M0 accepté pendant une passe (M3 perdu, M0 en trop sans contrôle de
cadence, nouvelle cadence) abandonne la passe en cours
(`passes_abandonnees` ; pas celle que l'arrêt coupe, `terminer_passes!`). `dernier` : le dernier temps lu (tics).

Pour le diagnostic (`EtatClamp`) : `marqueurs_vus` compte les fronts de
chaque marqueur M0–M3 depuis le début, `photons_par_code` les photons lus
pendant les passes par code de routage (le code réservé compris, avant
d'être jeté), `duree_min`/`duree_max`/`duree_derniere` les durées des
passes terminées et `intervalle_min`/`intervalle_max` les intervalles
M0 → M0 (tics ; -1 avant le premier).
"""
mutable struct Passes
    decodeur::Decodeur
    debuts::Vector{Int64}
    fins::Vector{Int64}
    t_photons::Vector{Int64}
    adc_photons::Vector{UInt16}
    routage_photons::Vector{UInt8}
    groupe::Int
    en_passe::Bool
    t_debut::Int64
    numero::Int
    histo::Matrix{UInt32}
    photons::Int
    pertes_debut::Int
    hors_passe::Int
    hors_roi::Int
    passes_abandonnees::Int
    dernier::Int64
    marqueurs_vus::Vector{Int}
    photons_par_code::Vector{Int}
    duree_min::Int64
    duree_max::Int64
    duree_derniere::Int64
    duree::Int64
    dernier_debut::Int64
    intervalle::Int64
    intervalle_min::Int64
    intervalle_max::Int64
    periode::Int64
    tolerance::Int64
    dernier_valide::Int64
    m0_hors_cadence::Int
    m0_manquants::Int
    hors_bords::Int
    hors_depuis_fin::Int                 # photons hors passe depuis la fin de la dernière passe
    passe_vue::Bool
end

function Passes(; canaux::Integer = 256, duree::Integer = 0, periode::Integer = 0, tolerance::Integer = 0)
    4096 % canaux == 0 || error("canaux : un diviseur de 4096")
    duree >= 0 || error("duree : en tics, positive (0 : fin au M3)")
    periode == 0 || (duree > 0 && periode > duree && tolerance >= 0) ||
        error("periode : M0 seul (duree > 0), en tics, plus longue que le scan")
    return Passes(Decodeur(garder_photons = true), Int64[], Int64[], Int64[], UInt16[], UInt8[],
                  4096 ÷ canaux, false, Int64(0), 0, zeros(UInt32, canaux, 16), 0, 0, 0, 0, 0, typemin(Int64),
                  zeros(Int, 4), zeros(Int, 16), Int64(-1), Int64(-1), Int64(-1),
                  Int64(duree), typemin(Int64), Int64(-1), Int64(-1), Int64(-1),
                  Int64(periode), Int64(tolerance), typemin(Int64), 0, 0, 0, 0, false)
end

"""
    passes!(f, p, mots, n=length(mots))

Décode les `n` premiers mots et range les photons dans les passes ;
`f(p, t_debut, t_fin, pertes)` à chaque passe terminée (voir `Passes`).
"""
function passes!(f, p::Passes, mots::AbstractVector{UInt16}, n::Integer = length(mots))
    d = p.decodeur
    decoder!(d, mots, n)
    for b in 1:4
        p.marqueurs_vus[b] += length(d.marqueurs[b])
    end
    append!(p.debuts, d.marqueurs[MARQUEUR_DEBUT])
    p.duree == 0 && append!(p.fins, d.marqueurs[MARQUEUR_FIN])        # M0 seul : les M3 ne comptent pas
    append!(p.t_photons, d.t_photons)
    append!(p.adc_photons, d.adc_photons)
    append!(p.routage_photons, d.routage_photons)
    # Le temps atteint par le flux : tout ce qui le précède est décodé (les
    # marqueurs ignorés et les débordements du macrotemps comptent aussi).
    limite = d.base
    for v in (d.marqueurs..., p.debuts, p.fins, p.t_photons)
        isempty(v) || (limite = max(limite, last(v)))
    end
    foreach(empty!, d.marqueurs)
    empty!(d.t_photons); empty!(d.adc_photons); empty!(d.routage_photons)
    p.dernier = max(p.dernier, limite)
    _passes_avant!(f, p, limite)
    return p
end

"""
Range tout ce qui attend. Une passe sans sa fin — la mesure arrêtée
pendant un scan, le cas normal — est laissée de côté sans être comptée
dans `passes_abandonnees` : ce n'est pas un défaut du signal de passe.
"""
function terminer_passes!(f, p::Passes)
    _passes_avant!(f, p, typemax(Int64))
    p.en_passe && _vider_passe!(p)
    # Après la dernière passe, la NI ne pilotait plus les lignes : pas un décalage.
    p.hors_passe -= p.hors_depuis_fin
    p.hors_bords += p.hors_depuis_fin
    p.hors_depuis_fin = 0
    return p
end

function _passes_avant!(f, p::Passes, limite::Int64)
    D, E, P = p.debuts, p.fins, p.t_photons
    tous = limite == typemax(Int64)
    i, j, k = 1, 1, 1
    @inbounds while true
        td = i <= length(D) && (tous || D[i] < limite) ? D[i] : typemax(Int64)
        te = j <= length(E) && (tous || E[j] < limite) ? E[j] : typemax(Int64)
        tp = k <= length(P) && (tous || P[k] < limite) ? P[k] : typemax(Int64)
        # M0 seul : la fin de la passe ouverte, sa durée après son M0.
        # À la fin de la mesure, seulement si les données vont jusque-là (sinon abandonnée).
        tf = p.en_passe && p.duree > 0 ? p.t_debut + p.duree : typemax(Int64)
        (tous ? tf <= p.dernier : tf < limite) || (tf = typemax(Int64))
        t = min(td, te, tp, tf)
        t == typemax(Int64) && break
        if tf == t || te == t                        # fin de passe
            p.en_passe && _finir_passe!(f, p, t)
            tf == t || (j += 1)
        elseif td == t                               # début de passe
            if _en_cadence!(p, td)
                p.en_passe && (p.passes_abandonnees += 1; _vider_passe!(p))
                p.en_passe = true
                p.t_debut = td
                p.passe_vue = true
                p.hors_depuis_fin = 0
            end
            if p.dernier_debut != typemin(Int64)
                p.intervalle = td - p.dernier_debut
                p.intervalle_min = p.intervalle_min < 0 ? p.intervalle : min(p.intervalle_min, p.intervalle)
                p.intervalle_max = max(p.intervalle_max, p.intervalle)
            end
            p.dernier_debut = td
            i += 1
        else                                         # photon
            code = Int(p.routage_photons[k])
            p.en_passe && (p.photons_par_code[code + 1] += 1)
            if code == CODE_HORS_ROI
                p.hors_roi += 1
            elseif p.en_passe
                p.histo[(4095 - Int(p.adc_photons[k])) ÷ p.groupe + 1, code + 1] += 1
                p.photons += 1
            elseif p.passe_vue
                p.hors_passe += 1
                p.hors_depuis_fin += 1
            else
                p.hors_bords += 1                    # avant la première passe
            end
            k += 1
        end
    end
    i > 1 && deleteat!(D, 1:i - 1)
    j > 1 && deleteat!(E, 1:j - 1)
    if k > 1
        deleteat!(P, 1:k - 1)
        deleteat!(p.adc_photons, 1:k - 1)
        deleteat!(p.routage_photons, 1:k - 1)
    end
    return nothing
end

"""Le M0 à `td` ouvre-t-il une passe ? Toujours, sauf hors cadence (voir `Passes`)."""
function _en_cadence!(p::Passes, td::Int64)
    p.periode > 0 && p.dernier_valide != typemin(Int64) || (p.dernier_valide = td; return true)
    ecart = td - p.dernier_valide
    n = round(Int64, ecart / p.periode)
    if n >= 1 && abs(ecart - n * p.periode) <= n * p.tolerance
        p.m0_manquants += n - 1
    elseif !(p.dernier_debut != typemin(Int64) && abs(td - p.dernier_debut - p.periode) <= p.tolerance)
        p.m0_hors_cadence += 1                       # parasite : ignoré
        return false
    end                                              # sinon : nouvelle cadence
    p.dernier_valide = td
    return true
end

function _finir_passe!(f, p::Passes, t_fin::Int64)
    pertes = p.decodeur.pertes - p.pertes_debut
    p.pertes_debut = p.decodeur.pertes
    p.numero += 1
    duree = t_fin - p.t_debut
    p.duree_derniere = duree
    p.duree_min = p.duree_min < 0 ? duree : min(p.duree_min, duree)
    p.duree_max = max(p.duree_max, duree)
    f(p, p.t_debut, t_fin, pertes)
    _vider_passe!(p)
    return nothing
end

function _vider_passe!(p::Passes)
    fill!(p.histo, 0)
    p.photons = 0
    p.en_passe = false
    return nothing
end

# ---------------------------------------------------------------------
# Flux synthétique du Realtime (simulation, session simulée)
# ---------------------------------------------------------------------

"""
    flux_passes_synthetique(; codes, passes, scan_s=0.95, pause_s=0.05, tic_s=25e-9,
                            photons_par_s=2e5, photons_pause_par_s=0, tau_ns=(code, t) -> 2.0,
                            irf_ns=1.0, irf_sigma_ns=0.08, fenetre_ns=12.5, graine=1, debut_s=0.05)
        -> Vector{UInt16}

Flux FIFO d'une mesure Realtime, au format des cartes : `passes` passes de
`scan_s`, séparées de `pause_s` ; la passe `n` (à partir de 1) porte le
code de routage `codes[mod1(n, length(codes))]`, M0 à son début et M3 à sa
fin. Les photons arrivent au hasard (`photons_par_s` pendant les scans,
`photons_pause_par_s` pendant les pauses, ceux-là avec le code réservé
`CODE_HORS_ROI`, comme la NI l'écrit) avec un déclin exponentiel de
`tau_ns(code, t)` (t : temps de la passe en s) décalé par une IRF
gaussienne (`irf_ns`, `irf_sigma_ns`).
"""
function flux_passes_synthetique(; codes::AbstractVector{<:Integer}, passes::Integer, scan_s::Real = 0.95,
                                 pause_s::Real = 0.05, tic_s::Real = 25e-9, photons_par_s::Real = 2e5,
                                 photons_pause_par_s::Real = 0,
                                 tau_ns = (code, t) -> 2.0, irf_ns::Real = 1.0, irf_sigma_ns::Real = 0.08,
                                 fenetre_ns::Real = 12.5, graine::Integer = 1, debut_s::Real = 0.05)
    a = Alea(graine)
    e = EncodeurFifo()
    dt_ns = fenetre_ns / 4096
    scan = round(Int64, scan_s / tic_s)
    periode = scan + round(Int64, pause_s / tic_s)
    t0 = round(Int64, debut_s / tic_s)
    gauss() = sqrt(-2 * log(1 - _uniforme!(a))) * cos(2π * _uniforme!(a))
    function photons!(de, duree, nombre, code, tau)
        temps = sort!([de + floor(Int64, _uniforme!(a) * duree) for _ in 1:nombre])
        for t in temps
            micro = irf_ns + irf_sigma_ns * gauss() - tau * log(1 - _uniforme!(a))
            canal = floor(Int, micro / dt_ns)
            0 <= canal < 4096 || continue
            photon!(e, t, 4095 - canal; routage = code)
        end
    end
    for n in 1:passes
        debut = t0 + (n - 1) * periode
        code = codes[mod1(n, length(codes))]
        tau = Float64(tau_ns(code, debut * tic_s))
        marqueur!(e, debut, 0b0001)
        photons!(debut, scan, round(Int, photons_par_s * scan_s * (0.95 + 0.1 * _uniforme!(a))), code, tau)
        marqueur!(e, debut + scan, 0b1000)
        pause = periode - scan
        pause > 1 && photons!(debut + scan + 1, pause - 1, round(Int, photons_pause_par_s * pause_s), CODE_HORS_ROI, tau)
    end
    return e.mots
end
