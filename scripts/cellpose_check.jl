# cellpose_check.jl — ce qui manque à Cellpose sur cet ordinateur, maillon
# par maillon, sans le GUI : pour départager un ROI-01 ou un ROI-02
# (DEBUGGING.md).
#
#     julia --project scripts/cellpose_check.jl
#
# 1. le Python de l'environnement que l'app attend (~/.flimapp/cellpose-env ;
#    sous Windows %USERPROFILE%\.flimapp\cellpose-env\Scripts\python.exe) ;
# 2. PyTorch (version, GPU) et Cellpose (version, modèles) dans ce Python ;
# 3. une segmentation d'une image de synthèse (des disques), par le même
#    chemin que le bouton Cellpose de la fenêtre ROI.
# La première segmentation télécharge le modèle (environ 1 Go) : il faut
# internet, et quelques minutes.
using FLIMApp

python = FLIMApp.cellpose_venv_python_path()
println("1. Python de l'environnement Cellpose : ", python)
if Sys.which(python) === nothing
    println("   ABSENT. Crée l'environnement une fois, ", FLIMApp.cellpose_setup_hint())
    exit(1)
end
println("   présent")

println("\n2. PyTorch et Cellpose dans ce Python :")
probe = """
import sys
print("   Python", sys.version.split()[0])
try:
    import torch
    print("   PyTorch", torch.__version__, "- GPU (CUDA) :", torch.cuda.is_available())
except Exception as e:
    print("   PyTorch NON IMPORTABLE :", type(e).__name__, e)
try:
    import cellpose
    from cellpose import models
    v = getattr(cellpose, "__version__", None)
    if v is None:
        from importlib.metadata import version
        v = version("cellpose")
    print("   Cellpose", v, "- modèles :", getattr(models, "MODEL_NAMES", "?"))
except Exception as e:
    print("   Cellpose NON IMPORTABLE :", type(e).__name__, e)
"""
try
    run(`$python -c $probe`)
catch e
    println("   ce Python ne démarre pas : ", e)
    exit(1)
end

println("\n3. Segmentation d'une image de synthèse (5 disques sur 256 × 256), comme le bouton Cellpose :")
image = zeros(256, 256)
for (cx, cy) in ((50, 60), (130, 70), (200, 190), (80, 180), (170, 120)), x in 1:256, y in 1:256
    (x - cx)^2 + (y - cy)^2 < 18^2 && (image[x, y] += 100 + 20 * rand())
end
image .+= 5 .* rand(256, 256)
t0 = time()
masks = FLIMApp.run_cellpose_segmentation(image)
if masks === nothing
    println("   ÉCHEC : ", FLIMApp.CELLPOSE_LAST_ERROR[])
    println("   (la trace complète de Python est juste au-dessus)")
    exit(1)
end
n = length(filter(!=(0), unique(masks)))
println("   ", FLIMApp.CELLPOSE_LAST_INFO[], " en ", round(time() - t0; digits = 1), " s")
println(n >= 4 ? "   RÉUSSI : $n objets trouvés (5 dessinés). Cellpose fonctionne ; si le bouton échoue encore, envoie le rapport de débogage." :
                 "   Cellpose tourne mais trouve $n objet(s) sur 5 : modèle ou version inhabituels, envoie cette sortie.")
