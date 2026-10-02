# passes.jl — les passes du mode Realtime dans le flux FIFO.
#
# Une passe est un scan d'une ROI (un créneau de la NI). Le signal de passe,
# haut pendant le scan, vient d'un compteur de la 6321 cadencé par l'horloge
# de l'AO ; il arrive sur deux marqueurs de chaque carte : M0, actif sur le
# front montant (début de passe), et M3, actif sur le front descendant (fin).
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
    Passes(; canaux=256)

Découpe un flux FIFO en passes, au fil des lectures (`passes!`). Entre un
M0 et le M3 suivant, chaque photon va dans `histo[canal, code + 1]`
(`canaux` canaux de temps croissant, 16 codes de routage). À chaque fin de
passe, `f(p, t_debut, t_fin, pertes)` (temps en tics, `pertes` : GAP
décodés depuis la passe précédente), puis l'histogramme repart de zéro.

À temps égal, une fin passe avant un début, et un début avant un photon :
un photon pile sur M0 est dans la passe, pile sur M3 il n'y est plus. Les
événements du dernier tic lu attendent la lecture suivante.

Les photons du code réservé (`CODE_HORS_ROI` : déplacements, pauses) sont
jetés et comptés dans `hors_roi` ; les autres photons hors passe (décalage
d'un échantillon entre le code et le signal de passe) dans `hors_passe`.
Un M0 sans M3 (marqueur perdu) abandonne la passe en cours
(`passes_abandonnees`). `dernier` : le dernier temps lu (tics).

Pour le diagnostic (`EtatClamp`) : `marqueurs_vus` compte les fronts de
chaque marqueur M0–M3 depuis le début, `photons_par_code` les photons lus
pendant les passes par code de routage (le code réservé compris, avant
d'être jeté), `duree_min`/`duree_max`/`duree_derniere` les durées M3 − M0
des passes terminées (tics ; -1 avant la première).
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
end

function Passes(; canaux::Integer = 256)
    4096 % canaux == 0 || error("canaux : un diviseur de 4096")
    return Passes(Decodeur(garder_photons = true), Int64[], Int64[], Int64[], UInt16[], UInt8[],
                  4096 ÷ canaux, false, Int64(0), 0, zeros(UInt32, canaux, 16), 0, 0, 0, 0, 0, typemin(Int64),
                  zeros(Int, 4), zeros(Int, 16), Int64(-1), Int64(-1), Int64(-1))
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
    append!(p.fins, d.marqueurs[MARQUEUR_FIN])
    append!(p.t_photons, d.t_photons)
    append!(p.adc_photons, d.adc_photons)
    append!(p.routage_photons, d.routage_photons)
    foreach(empty!, d.marqueurs)
    empty!(d.t_photons); empty!(d.adc_photons); empty!(d.routage_photons)
    limite = typemin(Int64)
    for v in (p.debuts, p.fins, p.t_photons)
        isempty(v) || (limite = max(limite, last(v)))
    end
    p.dernier = max(p.dernier, limite)
    _passes_avant!(f, p, limite)
    return p
end

"""Range tout ce qui attend ; une passe sans sa fin (mesure arrêtée pendant un scan) est abandonnée."""
function terminer_passes!(f, p::Passes)
    _passes_avant!(f, p, typemax(Int64))
    p.en_passe && (p.passes_abandonnees += 1; _vider_passe!(p))
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
        t = min(td, te, tp)
        t == typemax(Int64) && break
        if te == t                                   # fin de passe
            if p.en_passe
                pertes = p.decodeur.pertes - p.pertes_debut
                p.pertes_debut = p.decodeur.pertes
                p.numero += 1
                duree = te - p.t_debut
                p.duree_derniere = duree
                p.duree_min = p.duree_min < 0 ? duree : min(p.duree_min, duree)
                p.duree_max = max(p.duree_max, duree)
                f(p, p.t_debut, te, pertes)
                _vider_passe!(p)
            end
            j += 1
        elseif td == t                               # début de passe
            p.en_passe && (p.passes_abandonnees += 1; _vider_passe!(p))
            p.en_passe = true
            p.t_debut = td
            i += 1
        else                                         # photon
            code = Int(p.routage_photons[k])
            p.en_passe && (p.photons_par_code[code + 1] += 1)
            if code == CODE_HORS_ROI
                p.hors_roi += 1
            elseif p.en_passe
                p.histo[(4095 - Int(p.adc_photons[k])) ÷ p.groupe + 1, code + 1] += 1
                p.photons += 1
            else
                p.hors_passe += 1
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
