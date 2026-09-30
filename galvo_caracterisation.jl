# galvo_caracterisation.jl — délai de stabilisation du galvo : créneaux de
# -1 V à +1 V de plus en plus rapides, avec la PCIe-6321.
#
# Branchements (BNC-2090A de la 6321) :
#   AO 0 → té → AI 0 (retour de la commande) et → entrée J7 du driver du galvo ;
#   J6 du driver : broche 1 (position) → âme du BNC AI 1, broche 8 (masse) → blindage.
#   Commutateurs SE/DIFF de AI 0 et AI 1 réglés comme bornes_commande et
#   bornes_position (DIFF = réglage d'usine ; en DIFF, rien sur AI 8 ni AI 9).
# Avant : galvo alimenté ; laser inutile (coupé ou bloqué) ; ton GUI et tout
# programme qui se sert de la 6321 fermés. L'autre galvo n'est pas piloté.
# Le script appelle NI-DAQmx directement (nicaiu) : DAQmxLite n'est pas utilisé.
#
# Déroulé :
#   1. bloc de référence, créneau lent (5 Hz) : niveaux de position atteints,
#      gain position/commande (d'où le réglage du cavalier JP7), bruit, et
#      délai de stabilisation d'un saut complet de -1 V à +1 V. Si le galvo ne
#      bouge pas ou si le gain ne correspond à aucun réglage de JP7, on
#      s'arrête là ;
#   2. balayage : un bloc court (0,3 s) par fréquence, de plus en plus rapide,
#      avec une pause de 2 s à 0 V entre deux blocs. AO 0 est cadencée par
#      l'horloge d'échantillonnage de l'AI : chaque front de la commande tombe
#      exactement sur un échantillon. Le balayage s'arrête à la première
#      fréquence où le galvo n'atteint plus 95 % du saut, ou dès qu'il devient
#      instable (position au-delà de 1,6 fois le demi-saut, ou dépassement qui
#      grandit d'un front à l'autre) ;
#   3. bloc de contrôle à 5 Hz : les niveaux ont-ils bougé (échauffement) ?
# Dans tous les cas, AO 0 revient à 0 V. Un son à la fréquence du créneau est
# normal ; si le galvo grince, crie ou chauffe : Ctrl+C, UNE seule fois (le
# bloc en cours se termine, puis la sortie revient à 0 V).
#
# Délai de stabilisation à b % : temps après le front de la commande au-delà
# duquel la position reste à ±b % du saut autour de sa cible, jusqu'au front
# suivant. Donné sur la réponse moyenne de chaque sens (bruit réduit) et
# front par front (part des fronts stabilisés, médiane, maximum). Les deux
# premiers cycles de chaque bloc rapide sont écartés (régime établi).
#
# Sorties, dans resultats/galvo :
#   *_resume.csv          une ligne par fréquence et par sens ;
#   *_reponses.csv        réponses moyennes normalisées (0 au départ, 1 à la cible) ;
#   *_reponses.svg        ces réponses : montées en trait plein, descentes en tirets ;
#   *_stabilisation.svg   délais de stabilisation et demi-période selon la fréquence ;
#   *.jls                 données brutes (Serialization), pour tes analyses.
# Colle la sortie de la console dans la conversation.

Base.exit_on_sigint(false)          # Ctrl+C passe par la remise à 0 V, même hors REPL
using Printf, Dates, Serialization

galvo_reglages = (
    carte = "X6321",
    sortie = "ao0",                  # commande du galvo
    voie_commande = "ai0",           # retour de la commande (té sur AO 0)
    voie_position = "ai1",           # J6 : broche 1 (position), broche 8 (masse)
    bornes_commande = :diff,         # :diff, :rse ou :nrse, comme les commutateurs de la BNC-2090A
    bornes_position = :diff,
    fe = 100_000.0,                  # échantillons/s par voie (110 000 au plus)
    amplitude_v = 1.0,               # créneau de -amplitude à +amplitude ; 1 V au plus
    frequence_reference_hz = 5.0,    # bloc lent du début (20 Hz au plus)…
    cycles_reference = 10,           # … et ses cycles : la réponse moyenne en dépend (bruit)
    frequences_hz = [10, 20, 50, 100, 200, 300, 400, 500, 600, 700, 800, 1000],
    duree_bloc_s = 0.3,              # durée de chaque fréquence (1 s au plus)…
    cycles_min = 5,                  # … avec au moins ce nombre de cycles
    repos_s = 2.0,                   # pause à 0 V entre deux blocs, contre l'échauffement (1 s au moins)
    bandes = [0.05, 0.01, 0.002],    # bandes de stabilisation, en fraction du saut
                                     # (0,2 % ≈ un demi-pixel pour 256 pixels sur ±1 V)
)

const LIMITE_V = 1.0              # champ du galvo : jamais plus de ±1 V sur la sortie
const FREQUENCE_MAX_HZ = 1500.0   # au-delà, le moteur chauffe sans rien apprendre de plus
const PLAGE_AI = 5.0              # ±5 V sur les deux voies : même gain, pas d'écrêtage
const DELAI_CONVERSION_S = 1e-6   # première conversion 1 µs après le front d'horloge : AO 0 a déjà changé
const FE_MAX_VOIE = 110e3         # 1 µs de délai + 2 conversions de 4 µs (250 kS/s) par période
const SEUIL_SUIVI = 0.95          # le galvo « suit » s'il atteint 95 % du saut à chaque demi-période
const ECART_MAX = 1.6             # position au-delà de 1,6 fois le demi-saut : arrêt
const GAIN_MIN = 0.1              # en dessous, le galvo ne bouge pas (attendu 0,5 à 1)

const LIB_NI_GALVO = "nicaiu"
const GV_VOLTS = Int32(10348)     # DAQmx_Val_Volts
const GV_MONTANT = Int32(10280)   # DAQmx_Val_Rising
const GV_FINI = Int32(10178)      # DAQmx_Val_FiniteSamps
const GV_PAR_VOIE = UInt32(0)     # DAQmx_Val_GroupByChannel
const GV_VALIDER = Int32(3)       # DAQmx_Val_Task_Commit
const GV_SECONDES = Int32(10364)  # DAQmx_Val_Seconds

code_bornes(b) = b === :diff ? Int32(10106) : b === :rse ? Int32(10083) : b === :nrse ? Int32(10078) :
    error("bornes : :diff, :rse ou :nrse, comme les commutateurs de la BNC-2090A")

"Lève une erreur lisible pour un code NI-DAQmx négatif (les codes positifs sont des avertissements)."
function verif_ni(code)
    code >= 0 && return code
    tampon = zeros(UInt8, 2048)
    ccall((:DAQmxGetExtendedErrorInfo, LIB_NI_GALVO), Int32, (Ptr{UInt8}, UInt32), tampon, UInt32(length(tampon)))
    fin = something(findfirst(==(0x00), tampon), length(tampon) + 1)
    error("NI-DAQmx, erreur $code : " * String(tampon[1:fin - 1]))
end

"Crée une tâche NI-DAQmx, exécute f(tache), puis l'efface quoi qu'il arrive (ce qui l'arrête)."
function avec_tache(f, nom)
    th = Ref{Ptr{Cvoid}}(C_NULL)
    verif_ni(ccall((:DAQmxCreateTask, LIB_NI_GALVO), Int32, (Cstring, Ref{Ptr{Cvoid}}), nom, th))
    try
        return f(th[])
    finally
        ccall((:DAQmxClearTask, LIB_NI_GALVO), Int32, (Ptr{Cvoid},), th[])
    end
end

moyenne(x) = sum(x) / length(x)
function mediane(x)
    v = sort(collect(x))
    n = length(v)
    return isodd(n) ? v[(n + 1) ÷ 2] : (v[n ÷ 2] + v[n ÷ 2 + 1]) / 2
end
function ecart_type(x)
    m = moyenne(x)
    return sqrt(sum(abs2, x .- m) / max(1, length(x) - 1))
end

fmt_us(t) = isnan(t) ? "—" : @sprintf("%.0f", t * 1e6)
nom_bande(b) = replace(@sprintf("%g", 100 * b), "." => ",") * " %"

function verifier_reglages_galvo(r)
    0 < r.amplitude_v <= LIMITE_V || error("amplitude_v : entre 0 et $(LIMITE_V) V (champ du galvo)")
    f = Float64.(r.frequences_hz)
    all(0 .< f .<= FREQUENCE_MAX_HZ) || error("frequences_hz : entre 0 et $(FREQUENCE_MAX_HZ) Hz")
    issorted(f) || error("frequences_hz : en ordre croissant (le balayage s'arrête quand le galvo ne suit plus)")
    0 < r.frequence_reference_hz <= 20 ||
        error("frequence_reference_hz : 20 Hz au plus, pour que chaque saut se stabilise")
    r.fe <= FE_MAX_VOIE || error("fe : $(FE_MAX_VOIE) échantillons/s par voie au plus")
    r.fe >= 20_000 || error("fe : au moins 20 000 échantillons/s, sinon la stabilisation n'est pas résolue")
    isempty(f) || r.fe / (2 * maximum(f)) >= 10 ||
        error("fe trop basse pour $(maximum(f)) Hz : au moins 10 échantillons par demi-période")
    !isempty(r.bandes) && all(0 .< r.bandes .< 0.5) || error("bandes : fractions du saut, entre 0 et 0,5")
    0 < r.duree_bloc_s <= 1.0 || error("duree_bloc_s : 1 s au plus (échauffement du moteur)")
    r.cycles_min >= 3 || error("cycles_min : au moins 3")
    3 <= r.cycles_reference <= 5 * r.frequence_reference_hz ||
        error("cycles_reference : au moins 3, et 5 s de bloc au plus")
    r.repos_s >= 1.0 || error("repos_s : 1 s au moins (échauffement du moteur)")
    r.sortie in ("ao0", "ao1") || error("sortie : ao0 ou ao1")
    r.voie_commande != r.voie_position || error("voie_commande et voie_position : deux voies différentes")
    for (v, b) in ((r.voie_commande, r.bornes_commande), (r.voie_position, r.bornes_position))
        code_bornes(b)
        m = match(r"^ai([0-9]+)$", v)
        m === nothing && error("voie « $v » : ai0 à ai15")
        n = parse(Int, m.captures[1])
        n <= (b === :diff ? 7 : 15) ||
            error("voie « $v » : ai0 à ai7 en différentiel, ai0 à ai15 en simple (rse, nrse)")
    end
    return nothing
end

# ---------------------------------------------------------------------
# Créneau et acquisition
# ---------------------------------------------------------------------

"""
Créneau de ±A : rampe douce de 0 à -A (10 ms), tenue (20 ms), 2·cycles fronts
espacés d'une demi-période de h échantillons (entier), tenue à -A, rampe douce
vers 0. fronts[i] : premier échantillon au nouveau niveau ; sens[i] : +1 pour
une montée, -1 pour une descente.
"""
function creneau(fe, f, A, cycles)
    h = max(4, round(Int, fe / (2 * f)))
    nr = round(Int, 0.010 * fe)
    nt = round(Int, 0.020 * fe)
    onde = [-A * (1 - cos(pi * k / nr)) / 2 for k in 1:nr]
    append!(onde, fill(-A, nt))
    fronts, sens = Int[], Int[]
    for i in 0:(2 * cycles - 1)
        s = iseven(i) ? 1 : -1
        push!(fronts, length(onde) + 1)
        push!(sens, s)
        append!(onde, fill(s * A, h))
    end
    append!(onde, fill(-A, nt))
    append!(onde, [-A * (1 + cos(pi * k / nr)) / 2 for k in 1:nr])
    append!(onde, zeros(round(Int, 0.005 * fe)))
    maximum(abs, onde) <= LIMITE_V || error("créneau hors de ±$(LIMITE_V) V : rien n'est envoyé")
    return (onde = onde, fronts = fronts, sens = sens, h = h)
end

"""
Envoie le créneau sur la sortie et enregistre les deux voies d'entrée. L'AO
prend comme horloge celle de l'AI : l'échantillon k de l'AO sort au front
d'horloge où l'AI prend son échantillon k. La voie commande est convertie
DELAI_CONVERSION_S après ce front, la voie position une conversion plus tard.
Renvoie les deux voies, la cadence réelle et ce retard de la voie position.
"""
function acquerir_bloc(r, cr)
    onde = cr.onde
    n_ao = length(onde)
    n_ai = n_ao + round(Int, 0.005 * r.fe)          # 5 ms de plus : la sortie a fini, à 0 V
    donnees = zeros(Float64, 2 * n_ai)
    ecrits, lus = Ref{Int32}(0), Ref{Int32}(0)
    fe_reel, conv, delai = Ref{Float64}(0.0), Ref{Float64}(0.0), Ref{Float64}(0.0)
    conv_lue, delai_ok = false, false
    avec_tache("galvo_ai") do ai
        for (voie, bornes) in ((r.voie_commande, r.bornes_commande), (r.voie_position, r.bornes_position))
            verif_ni(ccall((:DAQmxCreateAIVoltageChan, LIB_NI_GALVO), Int32,
                           (Ptr{Cvoid}, Cstring, Cstring, Int32, Float64, Float64, Int32, Ptr{Cchar}),
                           ai, "$(r.carte)/$voie", "", code_bornes(bornes), -PLAGE_AI, PLAGE_AI, GV_VOLTS, C_NULL))
        end
        verif_ni(ccall((:DAQmxCfgSampClkTiming, LIB_NI_GALVO), Int32,
                       (Ptr{Cvoid}, Cstring, Float64, Int32, Int32, UInt64),
                       ai, "", r.fe, GV_MONTANT, GV_FINI, UInt64(n_ai)))
        # Délai de la première conversion. En cas de refus, retour au réglage par défaut.
        delai_ok = ccall((:DAQmxSetDelayFromSampClkDelayUnits, LIB_NI_GALVO), Int32,
                         (Ptr{Cvoid}, Int32), ai, GV_SECONDES) >= 0 &&
                   ccall((:DAQmxSetDelayFromSampClkDelay, LIB_NI_GALVO), Int32,
                         (Ptr{Cvoid}, Float64), ai, DELAI_CONVERSION_S) >= 0
        if !delai_ok
            ccall((:DAQmxResetDelayFromSampClkDelayUnits, LIB_NI_GALVO), Int32, (Ptr{Cvoid},), ai)
            ccall((:DAQmxResetDelayFromSampClkDelay, LIB_NI_GALVO), Int32, (Ptr{Cvoid},), ai)
        end
        code = ccall((:DAQmxTaskControl, LIB_NI_GALVO), Int32, (Ptr{Cvoid}, Int32), ai, GV_VALIDER)
        if code < 0 && delai_ok                     # délai refusé à la validation : sans délai, on réessaie
            ccall((:DAQmxResetDelayFromSampClkDelayUnits, LIB_NI_GALVO), Int32, (Ptr{Cvoid},), ai)
            ccall((:DAQmxResetDelayFromSampClkDelay, LIB_NI_GALVO), Int32, (Ptr{Cvoid},), ai)
            delai_ok = false
            code = ccall((:DAQmxTaskControl, LIB_NI_GALVO), Int32, (Ptr{Cvoid}, Int32), ai, GV_VALIDER)
        end
        verif_ni(code)
        verif_ni(ccall((:DAQmxGetSampClkRate, LIB_NI_GALVO), Int32, (Ptr{Cvoid}, Ref{Float64}), ai, fe_reel))
        conv_lue = ccall((:DAQmxGetAIConvRate, LIB_NI_GALVO), Int32,
                         (Ptr{Cvoid}, Ref{Float64}), ai, conv) >= 0 && conv[] > 0
        delai_ok = delai_ok && ccall((:DAQmxGetDelayFromSampClkDelay, LIB_NI_GALVO), Int32,
                                     (Ptr{Cvoid}, Ref{Float64}), ai, delai) >= 0
        avec_tache("galvo_ao") do ao
            verif_ni(ccall((:DAQmxCreateAOVoltageChan, LIB_NI_GALVO), Int32,
                           (Ptr{Cvoid}, Cstring, Cstring, Float64, Float64, Int32, Ptr{Cchar}),
                           ao, "$(r.carte)/$(r.sortie)", "", -LIMITE_V, LIMITE_V, GV_VOLTS, C_NULL))
            verif_ni(ccall((:DAQmxCfgSampClkTiming, LIB_NI_GALVO), Int32,
                           (Ptr{Cvoid}, Cstring, Float64, Int32, Int32, UInt64),
                           ao, "/$(r.carte)/ai/SampleClock", r.fe, GV_MONTANT, GV_FINI, UInt64(n_ao)))
            verif_ni(ccall((:DAQmxWriteAnalogF64, LIB_NI_GALVO), Int32,
                           (Ptr{Cvoid}, Int32, UInt32, Float64, UInt32, Ptr{Float64}, Ref{Int32}, Ptr{UInt32}),
                           ao, Int32(n_ao), UInt32(0), 10.0, GV_PAR_VOIE, onde, ecrits, C_NULL))
            ecrits[] == n_ao || error("écriture incomplète sur $(r.sortie) : $(ecrits[]) échantillons sur $n_ao")
            verif_ni(ccall((:DAQmxStartTask, LIB_NI_GALVO), Int32, (Ptr{Cvoid},), ao))   # attend l'horloge de l'AI
            verif_ni(ccall((:DAQmxStartTask, LIB_NI_GALVO), Int32, (Ptr{Cvoid},), ai))   # l'horloge part : AO et AI ensemble
            verif_ni(ccall((:DAQmxReadAnalogF64, LIB_NI_GALVO), Int32,
                           (Ptr{Cvoid}, Int32, Float64, UInt32, Ptr{Float64}, UInt32, Ref{Int32}, Ptr{UInt32}),
                           ai, Int32(n_ai), n_ai / r.fe + 5.0, GV_PAR_VOIE, donnees, UInt32(length(donnees)),
                           lus, C_NULL))
            verif_ni(ccall((:DAQmxWaitUntilTaskDone, LIB_NI_GALVO), Int32, (Ptr{Cvoid}, Float64), ao, 2.0))
        end
    end
    lus[] == n_ai || error("lecture incomplète : $(lus[]) échantillons sur $n_ai")
    fe = fe_reel[]
    retard = (delai_ok ? delai[] : 0.0) + (conv_lue ? 1 / conv[] : 0.0)
    return (f = fe / (2 * cr.h), h = cr.h, fronts = cr.fronts, sens = cr.sens, fe = fe,
            decalage = retard, delai = delai_ok ? delai[] : NaN, conversion = conv_lue ? 1 / conv[] : NaN,
            delai_ok = delai_ok, onde = onde, commande = donnees[1:n_ai], position = donnees[n_ai + 1:end])
end

"Remet la sortie à 0 V (tâche à la demande). Renvoie false en cas d'échec, sans lever d'erreur."
function mettre_a_zero(r)
    try
        avec_tache("galvo_zero") do th
            verif_ni(ccall((:DAQmxCreateAOVoltageChan, LIB_NI_GALVO), Int32,
                           (Ptr{Cvoid}, Cstring, Cstring, Float64, Float64, Int32, Ptr{Cchar}),
                           th, "$(r.carte)/$(r.sortie)", "", -LIMITE_V, LIMITE_V, GV_VOLTS, C_NULL))
            verif_ni(ccall((:DAQmxWriteAnalogScalarF64, LIB_NI_GALVO), Int32,
                           (Ptr{Cvoid}, UInt32, Float64, Float64, Ptr{UInt32}),
                           th, UInt32(1), 5.0, 0.0, C_NULL))
        end
        return true
    catch err
        println("ATTENTION : remise à 0 V de $(r.carte)/$(r.sortie) impossible (", sprint(showerror, err),
                "). La sortie garde sa dernière valeur (±$(LIMITE_V) V au plus) : relance le script, ",
                "ou remets-la à 0 V depuis NI MAX.")
        return false
    end
end

# ---------------------------------------------------------------------
# Analyse
# ---------------------------------------------------------------------

"Dernier quart de la demi-période qui commence à l'échantillon e : le plateau."
plateau(x, e, h) = view(x, e + h - max(1, h ÷ 4):e + h - 1)

"Niveaux atteints au bloc lent : ils servent de départ et de cible à tous les blocs."
function niveaux_reference(b, A)
    mont = [i for i in eachindex(b.fronts) if b.sens[i] > 0]
    desc = [i for i in eachindex(b.fronts) if b.sens[i] < 0]
    niveau(x, idx) = mediane([moyenne(plateau(x, b.fronts[i], b.h)) for i in idx])
    haut, bas = niveau(b.position, mont), niveau(b.position, desc)
    saut = haut - bas
    bruit = mediane([ecart_type(plateau(b.position, e, b.h)) for e in b.fronts])
    return (haut = haut, bas = bas, milieu = (haut + bas) / 2, saut = saut, gain = saut / (2 * A),
            c_haut = niveau(b.commande, mont), c_bas = niveau(b.commande, desc),
            bruit = bruit, bruit_rel = bruit / max(abs(saut), 1e-12))
end

"Réponse au front i, normalisée : 0 au niveau de départ, 1 à la cible (niveaux de référence)."
function reponse(b, ref, i)
    e = b.fronts[i] + ref.decal_fronts                   # 1 si la sortie a un échantillon de retard
    dep, cib = b.sens[i] > 0 ? (ref.bas, ref.haut) : (ref.haut, ref.bas)
    return (b.position[e:e + b.h - 1] .- dep) ./ (cib - dep)
end

"""
Mesures sur une réponse normalisée y ; y[1] est l'échantillon pris au front,
t0 le retard de la voie position sur ce front. Temps en secondes ; NaN pour
une bande que la position ne tient pas jusqu'au front suivant.
"""
function mesures(y, fe, t0, bandes)
    n = length(y)
    temps(k) = (k - 1) / fe + t0
    function passage(niv)
        k = findfirst(>=(niv), y)
        k === nothing && return NaN
        k == 1 && return temps(1)
        return temps(k - 1) + (niv - y[k - 1]) / (y[k] - y[k - 1]) / fe
    end
    n_conf = max(3, round(Int, 30e-6 * fe))       # la bande doit tenir au moins 30 µs avant le front suivant
    ts = map(bandes) do bd
        dernier = findlast(v -> abs(1 - v) > bd, y)
        dernier === nothing && return temps(1)
        n - dernier < n_conf && return NaN
        e1, e2 = abs(1 - y[dernier]), abs(1 - y[dernier + 1])
        return temps(dernier) + (e1 - bd) / (e1 - e2) / fe
    end
    m = max(3, n ÷ 20)
    return (t10 = passage(0.1), t50 = passage(0.5), t90 = passage(0.9),
            depassement = max(0.0, maximum(y) - 1), atteint = moyenne(view(y, n - m + 1:n)), ts = ts)
end

"Décalage, en échantillons, entre chaque front de la sortie et son passage à mi-hauteur sur la voie commande."
function alignement(b, ref)
    mil, sgn = (ref.c_haut + ref.c_bas) / 2, sign(ref.c_haut - ref.c_bas)
    L = Int[]
    for (e, s) in zip(b.fronts, b.sens)
        for j in max(1, e - 3):min(length(b.commande), e + 5)
            if s * sgn * (b.commande[j] - mil) > 0
                push!(L, j - e)
                break
            end
        end
    end
    return L
end

"""
Origine des temps, d'après le retour de la commande au bloc de référence. La
voie commande est convertie 1 µs après le front d'horloge : si la sortie
change bien à ce front, elle y est déjà vue (0 échantillon) ; vue un
échantillon plus tard, la sortie a un échantillon de retard, et chaque
fenêtre d'analyse commence un échantillon plus loin (decal_fronts = 1).
"""
function origine_temps(b, ref)
    L = alignement(b, ref)
    ech = fmt_us(1 / b.fe)
    if isempty(L)
        return (decal_fronts = 0,
                origine = "aucun front vu sur la voie commande (retour non branché ?) : origine des temps " *
                          "prise au front d'horloge")
    elseif !all(in((0, 1)), L) || !allequal(L)
        return (decal_fronts = 0,
                origine = "ATTENTION : fronts vus à $(sort(unique(L))) échantillons du front envoyé ; origine " *
                          "des temps prise au front d'horloge, à vérifier")
    elseif !b.delai_ok
        return (decal_fronts = 0,
                origine = "front vu " * (L[1] == 0 ? "au même échantillon" : "à l'échantillon suivant") *
                          " ; délai de conversion non réglé : origine des temps connue à un échantillon ($ech µs) près")
    elseif L[1] == 0
        return (decal_fronts = 0, origine = "front vu au même échantillon : la sortie change au front d'horloge (normal)")
    else
        return (decal_fronts = 1,
                origine = "front vu à l'échantillon suivant : la sortie change un échantillon ($ech µs) après " *
                          "le front d'horloge ; fenêtres d'analyse décalées d'autant")
    end
end

function stats_fronts(d, j)
    t = [p.ts[j] for p in d.fronts]
    ok = filter(!isnan, t)
    return (n = length(ok), total = length(t), med = isempty(ok) ? NaN : mediane(ok),
            max = length(ok) == length(t) ? maximum(ok) : NaN)
end

function analyser_bloc(b, ref, r)
    nf = length(b.fronts)
    exclus = b.h / b.fe >= 0.02 ? 0 : min(4, nf - 2)     # blocs rapides : les 2 premiers cycles écartés
    garde = (exclus + 1):nf
    Y = [reponse(b, ref, i) for i in garde]
    S = b.sens[garde]
    t0 = b.decalage                                      # retard de la voie position sur le front
    function un_sens(s)
        ys = Y[S .== s]
        moy = reduce(+, ys) ./ length(ys)
        return (moy = moy, m = mesures(moy, b.fe, t0, r.bandes),
                fronts = [mesures(y, b.fe, t0, r.bandes) for y in ys])
    end
    montee, descente = un_sens(1), un_sens(-1)

    # Sécurité : position trop loin du milieu, ou dépassement qui grandit
    zone = b.fronts[1]:(b.fronts[end] + b.h - 1)
    ecart = maximum(abs(b.position[k] - ref.milieu) for k in zone) / (abs(ref.saut) / 2)
    dep = [max(0.0, maximum(y) - 1) for y in Y]
    q = max(1, length(dep) ÷ 4)
    d0, d1 = moyenne(dep[1:q]), moyenne(dep[end - q + 1:end])
    croissance = length(dep) >= 8 && d1 > d0 + 0.05 && d1 > 1.5 * d0

    return (f = b.f, demi_periode = b.h / b.fe, n_fronts = nf, n_garde = length(garde), t0 = t0, fe = b.fe,
            montee = montee, descente = descente, ecart = ecart, croissance = croissance,
            dep_debut = d0, dep_fin = d1,
            suit = min(montee.m.atteint, descente.m.atteint) >= SEUIL_SUIVI,
            sature = maximum(abs, b.position) > 0.98 * PLAGE_AI || maximum(abs, b.commande) > 0.98 * PLAGE_AI,
            alignement = alignement(b, ref))
end

function verdict_securite(a)
    a.ecart > ECART_MAX &&
        return @sprintf("position à %.2f fois le demi-saut (limite %.1f) à %.4g Hz : instabilité possible", a.ecart, ECART_MAX, a.f)
    a.croissance &&
        return @sprintf("dépassement qui grandit d'un front à l'autre à %.4g Hz (%.1f %% → %.1f %% du saut)",
                        a.f, 100 * a.dep_debut, 100 * a.dep_fin) *
               " : alimentation du galvo trop faible pour ce rythme (manuel GVS002, Troubleshooting)"
    return ""
end

"Réglage du cavalier JP7 (V/°) qui explique le gain position/commande, ou NaN."
function cavalier(gain)
    v = argmin(v -> abs(abs(gain) - 0.5 / v) / (0.5 / v), (0.5, 0.8, 1.0))
    return abs(abs(gain) - 0.5 / v) / (0.5 / v) <= 0.08 ? v : NaN
end

# ---------------------------------------------------------------------
# Affichage
# ---------------------------------------------------------------------

function afficher_reference(ref, b, A, r)
    @printf("  commande relue sur %s : %+.4f V / %+.4f V (attendu ±%g V)", r.voie_commande, ref.c_haut, ref.c_bas, A)
    tol = 0.03 * A + 0.005
    ok = abs(ref.c_haut - A) <= tol && abs(ref.c_bas + A) <= tol
    println(ok ? "" : "  ← ATTENTION : ce n'est pas ±$A V (té, câble, voie ou commutateur SE/DIFF)")
    println("  origine des temps : ", ref.origine)
    @printf("  position : haut %+.4f V, bas %+.4f V, saut %+.4f V ; gain position/commande %+.3f\n",
            ref.haut, ref.bas, ref.saut, ref.gain)
    @printf("  bruit de position : %.3f mV rms (%.3f %% du saut)\n", ref.bruit * 1e3, 100 * ref.bruit_rel)
    println("  voie position lue ", @sprintf("%.1f", b.decalage * 1e6), " µs après le front (délai ",
            isnan(b.delai) ? "non réglé" : @sprintf("%.2f µs", b.delai * 1e6), ", conversion ",
            isnan(b.conversion) ? "illisible" : @sprintf("%.2f µs", b.conversion * 1e6), ") : pris en compte")
    abs(b.fe / r.fe - 1) < 1e-3 || @printf("  cadence réelle : %.1f échantillons/s par voie\n", b.fe)
    return nothing
end

function entete_tableau(bandes, bruit_rel)
    print("\n  f (Hz)  ½ pér. µs  sens      t50 µs  t90 µs  dépass.  atteint")
    for bd in bandes
        print(lpad("t " * nom_bande(bd), 10))
    end
    println("   fronts stabilisés (", join(nom_bande.(bandes), " / "), ")")
    println("  (délais t : réponse moyenne, µs ; — = pas stabilisé avant le front suivant",
            any(bd -> bd < 3 * bruit_rel, bandes) ? " ; * = bande sous 3 σ du bruit : lire la moyenne)" : ")")
    return nothing
end

function afficher_bloc(a, bandes, bruit_rel)
    for (nom, d) in (("montée", a.montee), ("descente", a.descente))
        m = d.m
        @printf("%8.4g  %9.0f  %-8s %7s %7s  %5.1f %%  %5.1f %%", a.f, a.demi_periode * 1e6, nom,
                fmt_us(m.t50), fmt_us(m.t90), 100 * m.depassement, 100 * m.atteint)
        for t in m.ts
            print(lpad(fmt_us(t), 10))
        end
        print("  ")
        for j in eachindex(bandes)
            s = stats_fronts(d, j)
            print(" ", s.n, "/", s.total, bandes[j] < 3 * bruit_rel ? "*" : "")
        end
        println()
    end
    a.sature && println("          ATTENTION : une voie frôle ±$(PLAGE_AI) V (écrêtage possible)")
    L = a.alignement
    !isempty(L) && !all(in((0, 1)), L) &&
        println("          ATTENTION : front de la commande vu à $(sort(unique(L))) échantillons du front envoyé")
    return nothing
end

function synthese(m, r, A)
    ref, res = m[:ref], m[:res]
    println("\n== Synthèse ==")
    v = cavalier(ref.gain)
    @printf("Gain position/commande %+.3f", ref.gain)
    if isnan(v)
        println(" : ne correspond à aucun réglage du cavalier JP7 (0,5 / 0,8 / 1 V/° → gain 1 / 0,625 / 0,5). ",
                "Vérifie la voie position, le câble J6 et le commutateur SE/DIFF.")
    else
        @printf(" → cavalier JP7 à %g V/°%s ; ±%g V = ±%.3g° mécaniques (±%.3g° optiques)\n",
                v, v == 0.8 ? " (réglage d'usine)" : "", A, A / v, 2 * A / v)
    end
    ref.gain < 0 && println("Position de signe opposé à la commande : pris en compte dans l'analyse.")
    isempty(res) && return nothing

    a = res[1]
    @printf("Saut complet de %+g V à %+g V et retour (bloc de référence, réponse moyenne) :\n", -A, A)
    for (nom, d) in (("montée", a.montee), ("descente", a.descente))
        print("  ", rpad(nom, 9), ": 50 % à ", fmt_us(d.m.t50), " µs ; stabilisé à ",
              join(("$(nom_bande(bd)) en $(fmt_us(t)) µs" for (bd, t) in zip(r.bandes, d.m.ts)), ", "))
        @printf(" ; dépassement %.1f %%\n", 100 * d.m.depassement)
    end

    tries = sort(res; by = x -> x.f)
    println("Fréquence la plus haute où la position tient la bande à chaque demi-période (deux sens, sans trou) :")
    for (j, bd) in enumerate(r.bandes)
        fmax = NaN
        for x in tries
            (isnan(x.montee.m.ts[j]) || isnan(x.descente.m.ts[j])) && break
            fmax = x.f
        end
        if isnan(fmax)
            println("  ", rpad(nom_bande(bd), 7), ": aucune (même au bloc de référence)")
        else
            @printf("  %-7s: %.4g Hz (demi-période %.0f µs)\n", nom_bande(bd), fmax, 1e6 / (2 * fmax))
        end
    end
    @printf("Bruit de position %.3f mV rms, soit %.3f %% du saut.\n", ref.bruit * 1e3, 100 * ref.bruit_rel)

    fin = get(m, :fin, nothing)
    if fin !== nothing
        dh, db = fin.haut - ref.haut, fin.bas - ref.bas
        pire = max(abs(dh), abs(db)) / abs(ref.saut)
        print("Bloc de contrôle (après $(r.repos_s) s de pause, galvo un peu refroidi) : ")
        @printf("niveaux déplacés de %+.2f mV (haut) et %+.2f mV (bas), soit %.3f %% du saut au plus",
                dh * 1e3, db * 1e3, 100 * pire)
        fines = [nom_bande(bd) for bd in r.bandes if pire > bd / 2]
        println(isempty(fines) ? " : négligeable." :
                " : dérive (échauffement ?) comparable à la bande de " * join(fines, ", ") *
                " ; aux fréquences hautes, « pas stabilisé » peut venir de là.")
    end
    return nothing
end

# ---------------------------------------------------------------------
# Fichiers
# ---------------------------------------------------------------------

echapper(s) = replace(s, "&" => "&amp;", "<" => "&lt;", ">" => "&gt;")

function graduations(a, b)
    pas = (b - a) / 6
    e = 10.0^floor(log10(pas))
    pas = first(k * e for k in (1, 2, 5, 10) if k * e >= pas * (1 - 1e-9))
    return collect(ceil(a / pas - 1e-9) * pas + 0.0:pas:b + 1e-9 * pas)   # + 0.0 : pas de « -0 »
end

function graduations_log(a, b)
    v = Float64[]
    for d in floor(Int, log10(a)):ceil(Int, log10(b)), k in (1, 2, 5)
        x = k * 10.0^d
        a <= x <= b && push!(v, x)
    end
    return v
end

"""
Courbes dans un SVG. series : NamedTuple (x, y, couleur, tirets, points, nom).
Les points hors du cadre ou NaN coupent la courbe ; nom vide : pas de légende.
"""
function svg_courbes(chemin, titre, xnom, ynom, series; xlim, ylim, xlog = false, horizontales = Float64[])
    L, H = 860, 480
    mg, md, mh, mb = 70, 200, 50, 56
    lx, ly = L - mg - md, H - mh - mb
    (x0, x1), (y0, y1) = xlim, ylim
    u(x) = xlog ? (log10(x) - log10(x0)) / (log10(x1) - log10(x0)) : (x - x0) / (x1 - x0)
    X(x) = mg + lx * u(x)
    Y(y) = mh + ly * (y1 - y) / (y1 - y0)
    dedans(x, y) = isfinite(x) && isfinite(y) && x0 <= x <= x1 && y0 <= y <= y1
    open(chemin, "w") do io
        println(io, """<svg xmlns="http://www.w3.org/2000/svg" width="$L" height="$H" font-family="sans-serif" font-size="12">""")
        println(io, """<rect width="$L" height="$H" fill="white"/>""")
        println(io, """<text x="$mg" y="28" font-size="15">$(echapper(titre))</text>""")
        for x in (xlog ? graduations_log(x0, x1) : graduations(x0, x1))
            @printf(io, "<line x1=\"%.1f\" y1=\"%d\" x2=\"%.1f\" y2=\"%d\" stroke=\"#e5e7eb\"/>\n", X(x), mh, X(x), mh + ly)
            @printf(io, "<text x=\"%.1f\" y=\"%d\" text-anchor=\"middle\">%g</text>\n", X(x), mh + ly + 18, x)
        end
        for y in graduations(y0, y1)
            @printf(io, "<line x1=\"%d\" y1=\"%.1f\" x2=\"%d\" y2=\"%.1f\" stroke=\"#e5e7eb\"/>\n", mg, Y(y), mg + lx, Y(y))
            @printf(io, "<text x=\"%d\" y=\"%.1f\" text-anchor=\"end\">%g</text>\n", mg - 6, Y(y) + 4, y)
        end
        for y in horizontales
            y0 <= y <= y1 &&
                @printf(io, "<line x1=\"%d\" y1=\"%.1f\" x2=\"%d\" y2=\"%.1f\" stroke=\"#6b7280\" stroke-dasharray=\"2,3\"/>\n",
                        mg, Y(y), mg + lx, Y(y))
        end
        @printf(io, "<rect x=\"%d\" y=\"%d\" width=\"%d\" height=\"%d\" fill=\"none\" stroke=\"black\"/>\n", mg, mh, lx, ly)
        @printf(io, "<text x=\"%.1f\" y=\"%d\" text-anchor=\"middle\">%s</text>\n", mg + lx / 2, H - 14, echapper(xnom))
        @printf(io, "<text transform=\"translate(18,%.1f) rotate(-90)\" text-anchor=\"middle\">%s</text>\n",
                mh + ly / 2, echapper(ynom))
        for s in series
            style = s.tirets ? " stroke-dasharray=\"6,4\"" : ""
            seg = String[]
            function tracer!()
                length(seg) >= 2 &&
                    println(io, "<polyline fill=\"none\" stroke=\"$(s.couleur)\" stroke-width=\"1.4\"$style points=\"",
                            join(seg, ' '), "\"/>")
                empty!(seg)
            end
            for (x, y) in zip(s.x, s.y)
                dedans(x, y) ? push!(seg, @sprintf("%.1f,%.1f", X(x), Y(y))) : tracer!()
            end
            tracer!()
            if s.points
                for (x, y) in zip(s.x, s.y)
                    dedans(x, y) && @printf(io, "<circle cx=\"%.1f\" cy=\"%.1f\" r=\"3\" fill=\"%s\"/>\n", X(x), Y(y), s.couleur)
                end
            end
        end
        k = 0
        for s in series
            isempty(s.nom) && continue
            yl = mh + 8 + 16 * k
            @printf(io, "<line x1=\"%d\" y1=\"%d\" x2=\"%d\" y2=\"%d\" stroke=\"%s\" stroke-width=\"2\"%s/>\n",
                    mg + lx + 12, yl, mg + lx + 36, yl, s.couleur, s.tirets ? " stroke-dasharray=\"6,4\"" : "")
            @printf(io, "<text x=\"%d\" y=\"%d\">%s</text>\n", mg + lx + 42, yl + 4, echapper(s.nom))
            k += 1
        end
        println(io, "</svg>")
    end
    return chemin
end

couleur_rang(i, n) = "hsl($(round(Int, 220 - 220 * (i - 1) / max(1, n - 1))),75%,42%)"

function ecrire_resultats(prefixe, m, r, A, debut, arret)
    ref, res = m[:ref], m[:res]
    fe, t0 = res[1].fe, res[1].t0
    col(bd) = replace(@sprintf("%g", 100 * bd), "." => "p") * "pct"
    g(x) = @sprintf("%.6g", x)

    open(prefixe * "_resume.csv", "w") do io
        println(io, "# galvo_caracterisation.jl, ", Dates.format(debut, "yyyy-mm-dd HH:MM:SS"))
        println(io, "# carte $(r.carte), sortie $(r.sortie), commande $(r.voie_commande) ($(r.bornes_commande)), ",
                "position $(r.voie_position) ($(r.bornes_position))")
        @printf(io, "# fe %.1f éch/s par voie ; voie position lue %.2f µs après le front de la commande (pris en compte)\n",
                fe, t0 * 1e6)
        println(io, "# origine des temps : ", ref.origine)
        @printf(io, "# créneau ±%g V ; position haut %.5f V, bas %.5f V ; gain %.4f ; bruit %.3f mV rms\n",
                A, ref.haut, ref.bas, ref.gain, ref.bruit * 1e3)
        isempty(arret) || println(io, "# arrêt anticipé : ", arret)
        println(io, "# temps en µs depuis le front de la commande ; NaN = pas stabilisé avant le front suivant ;")
        println(io, "# t_* : réponse moyenne ; part_*, *_mediane, *_max : front par front (max NaN si un front ne se stabilise pas)")
        sous = [nom_bande(bd) for bd in r.bandes if bd < 3 * ref.bruit_rel]
        isempty(sous) ||
            println(io, "# bandes sous 3 σ du bruit, front par front non significatif (lire t_*) : ", join(sous, ", "))
        cols = ["frequence_hz", "demi_periode_us", "sens", "fronts_analyses", "t10_us", "t50_us", "t90_us",
                "depassement_pct", "atteint_pct"]
        for bd in r.bandes
            c = col(bd)
            append!(cols, ["t_$(c)_us", "part_stabilises_$(c)", "t_$(c)_mediane_us", "t_$(c)_max_us"])
        end
        println(io, join(cols, ","))
        for a in res, (nom, d) in (("montee", a.montee), ("descente", a.descente))
            v = String[g(a.f), g(a.demi_periode * 1e6), nom, string(length(d.fronts)),
                       g(d.m.t10 * 1e6), g(d.m.t50 * 1e6), g(d.m.t90 * 1e6),
                       g(100 * d.m.depassement), g(100 * d.m.atteint)]
            for j in eachindex(r.bandes)
                s = stats_fronts(d, j)
                append!(v, [g(d.m.ts[j] * 1e6), g(s.n / s.total), g(s.med * 1e6), g(s.max * 1e6)])
            end
            println(io, join(v, ","))
        end
    end

    open(prefixe * "_reponses.csv", "w") do io
        println(io, "# réponses moyennes normalisées : 0 = position de départ, 1 = position cible (niveaux du bloc de référence)")
        println(io, "# temps_us : depuis le front de la commande ; chaque colonne s'arrête au front suivant")
        noms = String["temps_us"]
        for a in res
            fs = replace(@sprintf("%.4g", a.f), "." => "p")
            push!(noms, "montee_$(fs)Hz", "descente_$(fs)Hz")
        end
        println(io, join(noms, ","))
        nmax = maximum(length(a.montee.moy) for a in res)
        for k in 1:nmax
            print(io, @sprintf("%.2f", ((k - 1) / fe + t0) * 1e6))
            for a in res, y in (a.montee.moy, a.descente.moy)
                print(io, ",", k <= length(y) ? @sprintf("%.5f", y[k]) : "")
            end
            println(io)
        end
    end

    # Réponses moyennes
    bm = r.bandes[min(2, length(r.bandes))]
    t_ref = filter(!isnan, vcat(res[1].montee.m.ts, res[1].descente.m.ts))
    xmax = min(res[1].demi_periode, max(1e-3, 2.5 * (isempty(t_ref) ? 0.0 : maximum(t_ref))))
    series = NamedTuple[]
    for (i, a) in enumerate(res)
        c = i == 1 ? "#111827" : couleur_rang(i - 1, length(res) - 1)
        tt = [((k - 1) / fe + t0) * 1e6 for k in eachindex(a.montee.moy)]
        push!(series, (x = tt, y = a.montee.moy, couleur = c, tirets = false, points = false,
                       nom = @sprintf("%.4g Hz%s", a.f, i == 1 ? " (réf.)" : "")))
        push!(series, (x = tt, y = a.descente.moy, couleur = c, tirets = true, points = false, nom = ""))
    end
    svg_courbes(prefixe * "_reponses.svg",
                "Galvo : réponse moyenne aux fronts de ±$(A) V (plein : montée, tirets : descente)",
                "temps après le front de la commande (µs)",
                "fraction du saut (pointillés : ±$(nom_bande(bm)))", series;
                xlim = (0.0, xmax * 1e6), ylim = (-0.2, 1.4), horizontales = [1 - bm, 1.0, 1 + bm])

    # Délais selon la fréquence
    tries = sort(res; by = x -> x.f)
    fs = [a.f for a in tries]
    palette = ("#1d4ed8", "#059669", "#d97706", "#7c3aed", "#db2777")
    series = NamedTuple[]
    for (j, bd) in enumerate(r.bandes)
        push!(series, (x = fs, y = [max(a.montee.m.ts[j], a.descente.m.ts[j]) * 1e6 for a in tries],
                       couleur = palette[mod1(j, length(palette))], tirets = false, points = true,
                       nom = "stabilisé à $(nom_bande(bd))"))
    end
    push!(series, (x = fs, y = [max(a.montee.m.t50, a.descente.m.t50) * 1e6 for a in tries],
                   couleur = "#6b7280", tirets = true, points = true, nom = "50 % du saut"))
    fx = (minimum(fs) / 1.5, maximum(fs) * 1.5)
    grille = exp.(range(log(fx[1]), log(fx[2]); length = 80))
    push!(series, (x = grille, y = 1e6 ./ (2 .* grille), couleur = "#dc2626", tirets = true, points = false,
                   nom = "demi-période"))
    vals = filter(isfinite, vcat((s.y for s in series[1:end - 1])...))
    ymax = max(100.0, 1.3 * (isempty(vals) ? 0.0 : maximum(vals)))
    svg_courbes(prefixe * "_stabilisation.svg",
                "Galvo : délais après chaque front (pire des deux sens, réponse moyenne)",
                "fréquence du créneau (Hz)", "temps après le front (µs)", series;
                xlim = fx, ylim = (0.0, ymax), xlog = true)
    return nothing
end

# ---------------------------------------------------------------------
# Programme
# ---------------------------------------------------------------------

"""
Bloc de référence, balayage, puis bloc de contrôle. Renvoie la raison d'un
arrêt anticipé, ou "". Après un arrêt de sécurité, pas de bloc de contrôle.
"""
function mesurer!(m, r, A)
    fe = Float64(r.fe)
    cr = creneau(fe, Float64(r.frequence_reference_hz), A, r.cycles_reference)
    @printf("\n1. Bloc de référence : créneau à %.4g Hz, %d cycles\n", fe / (2 * cr.h), r.cycles_reference)
    b = acquerir_bloc(r, cr)
    push!(m[:blocs], b)
    ref = niveaux_reference(b, A)
    ref = merge(ref, origine_temps(b, ref))
    m[:ref] = ref
    afficher_reference(ref, b, A, r)
    abs(ref.gain) >= GAIN_MIN ||
        return @sprintf("le galvo ne bouge pas (gain position/commande %+.3f, attendu 0,5 à 1)", ref.gain) *
               " : alimentation du driver, câble J6 (broche 1 → âme, broche 8 → blindage), voie " *
               "$(r.voie_position) et son commutateur SE/DIFF, ou protection thermique du driver (moteur coupé 4 s)"
    a = analyser_bloc(b, ref, r)
    push!(m[:res], a)
    isnan(cavalier(ref.gain)) &&
        return @sprintf("gain position/commande %+.3f : aucun réglage du cavalier JP7 ne donne ça", ref.gain) *
               " (0,5 / 0,8 / 1 V/° → 1 / 0,625 / 0,5). Balayage non lancé : vérifie la voie position et son câblage"
    println("\n2. Balayage (blocs de $(r.duree_bloc_s) s, pause de $(r.repos_s) s à 0 V entre deux blocs)")
    entete_tableau(r.bandes, ref.bruit_rel)
    afficher_bloc(a, r.bandes, ref.bruit_rel)
    raison = verdict_securite(a)
    isempty(raison) || return raison

    raison = ""
    for f in r.frequences_hz
        sleep(r.repos_s)
        cycles = max(r.cycles_min, ceil(Int, r.duree_bloc_s * f))
        b = acquerir_bloc(r, creneau(fe, Float64(f), A, cycles))
        push!(m[:blocs], b)
        a = analyser_bloc(b, ref, r)
        push!(m[:res], a)
        afficher_bloc(a, r.bandes, ref.bruit_rel)
        s = verdict_securite(a)
        isempty(s) || return s
        if !a.suit
            raison = @sprintf("le galvo ne suit plus à %.4g Hz (moins de %.0f %% du saut atteint) : balayage arrêté là",
                              a.f, 100 * SEUIL_SUIVI)
            break
        end
    end

    sleep(r.repos_s)
    cr = creneau(fe, Float64(r.frequence_reference_hz), A, 3)
    @printf("\n3. Bloc de contrôle : créneau à %.4g Hz, 3 cycles\n", fe / (2 * cr.h))
    try
        b = acquerir_bloc(r, cr)
        push!(m[:blocs], b)
        m[:fin] = niveaux_reference(b, A)
    catch err
        err isa InterruptException && rethrow()
        println("  bloc de contrôle impossible : ", sprint(showerror, err))
    end
    return raison
end

function caracteriser_galvo(r)
    verifier_reglages_galvo(r)
    A = Float64(r.amplitude_v)
    dossier = joinpath(@__DIR__, "resultats", "galvo")
    mkpath(dossier)
    debut = now()
    prefixe = joinpath(dossier, Dates.format(debut, "yyyymmdd_HHMMSS") * "_galvo")
    @printf("Galvo piloté par %s/%s (créneau ±%g V), commande relue sur %s (%s), position sur %s (%s)\n",
            r.carte, r.sortie, A, r.voie_commande, r.bornes_commande, r.voie_position, r.bornes_position)

    m = Dict{Symbol,Any}(:blocs => Any[], :res => Any[], :ref => nothing)
    arret = ""
    try
        arret = mesurer!(m, r, A)
    catch err
        arret = err isa InterruptException ? "interrompu (Ctrl+C)" : "erreur : " * sprint(showerror, err)
    finally
        # un second Ctrl+C ne doit couper ni la remise à 0 V, ni l'écriture des résultats
        try
            Base.disable_sigint(() -> mettre_a_zero(r)) && println("\n$(r.carte)/$(r.sortie) remise à 0 V.")
        catch e
            e isa InterruptException || rethrow()
        end
    end
    isempty(arret) || println("ARRÊT : ", arret, ".")
    isempty(m[:blocs]) && return nothing

    # Données brutes d'abord : elles restent même si la suite échoue
    serialize(prefixe * ".jls", Dict("reglages" => r, "reference" => m[:ref], "controle" => get(m, :fin, nothing),
                                     "blocs" => m[:blocs], "resultats" => m[:res], "arret" => arret))
    m[:ref] === nothing || synthese(m, r, A)
    if m[:ref] !== nothing && !isempty(m[:res])
        ecrire_resultats(prefixe, m, r, A, debut, arret)
        println("\nFichiers : ", prefixe, ".jls, _resume.csv, _reponses.csv, _reponses.svg, _stabilisation.svg")
    else
        println("\nDonnées brutes : ", prefixe, ".jls")
    end
    println("Colle cette sortie dans la conversation.")
    return nothing
end

caracteriser_galvo(galvo_reglages)
