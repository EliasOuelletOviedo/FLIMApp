"""
    DAQmxLite

Interface minimale vers NI-DAQmx via ccall sur nicaiu.dll (64 bits).
Indépendante de la version du pilote : aucune table de constantes
générée, seulement les quelques valeurs utilisées ici.

Les valeurs numériques des constantes sont celles de NIDAQmx.h. Si un
appel renvoie une erreur du type "requested value is not a supported
value for this property", recoupe la constante avec le header :
  C:\\Program Files (x86)\\National Instruments\\Shared\\
      ExternalCompilerSupport\\C\\include\\NIDAQmx.h
"""
module DAQmxLite

export DAQmxError, chk, last_error
export device_names, driver_version, product_type, serial_number
export ai_channels, ao_channels, do_lines, terminals
export self_test, reset_device
export create_task, start_task, stop_task, clear_task, withtask
export add_ao_voltage, add_ai_voltage, add_do
export set_ai_coupling, get_ai_max, cfg_sample_clock
export write_analog, read_analog, write_do
export ai_once, ai_block, ao_hold
export Val_Volts, Val_Rising, Val_Falling, Val_FiniteSamps, Val_ContSamps
export Val_GroupByChannel, Val_GroupByScanNumber
export Val_ChanPerLine, Val_ChanForAllLines, Val_Cfg_Default
export Val_Diff, Val_RSE, Val_NRSE, Val_AC, Val_DC

const LIB = "nicaiu"
const TaskHandle = Ptr{Nothing}

# ---- constantes NIDAQmx.h ------------------------------------------
const Val_Volts             = Int32(10348)
const Val_Rising            = Int32(10280)
const Val_Falling           = Int32(10171)
const Val_FiniteSamps       = Int32(10178)
const Val_ContSamps         = Int32(10123)
const Val_GroupByChannel    = Int32(0)
const Val_GroupByScanNumber = Int32(1)
const Val_ChanPerLine       = Int32(0)
const Val_ChanForAllLines   = Int32(1)
const Val_Cfg_Default       = Int32(-1)
const Val_Diff              = Int32(10106)
const Val_RSE               = Int32(10083)
const Val_NRSE              = Int32(10078)
const Val_AC                = Int32(10045)
const Val_DC                = Int32(10050)

# ---- erreurs -------------------------------------------------------
struct DAQmxError <: Exception
    code::Int32
    msg::String
end
Base.showerror(io::IO, e::DAQmxError) =
    print(io, "DAQmx ", e.code, " : ", e.msg)

function last_error()
    buf = zeros(UInt8, 4096)
    ccall((:DAQmxGetExtendedErrorInfo, LIB), Int32,
          (Ptr{UInt8}, UInt32), buf, UInt32(length(buf)))
    return GC.@preserve buf unsafe_string(pointer(buf))
end

"""Vérifie un code de retour DAQmx : < 0 lève, > 0 avertit."""
function chk(code::Int32)
    if code < 0
        throw(DAQmxError(code, last_error()))
    elseif code > 0
        @warn "DAQmx avertissement $code : $(last_error())"
    end
    return code
end

# ---- interrogation du système --------------------------------------
_splitlist(s) = String[String(strip(x)) for x in split(s, ',') if !isempty(strip(x))]

function device_names()
    buf = zeros(UInt8, 4096)
    chk(ccall((:DAQmxGetSysDevNames, LIB), Int32,
              (Ptr{UInt8}, UInt32), buf, UInt32(length(buf))))
    return _splitlist(GC.@preserve buf unsafe_string(pointer(buf)))
end

function driver_version()
    maj = Ref{UInt32}(0); mnr = Ref{UInt32}(0); upd = Ref{UInt32}(0)
    chk(ccall((:DAQmxGetSysNIDAQMajorVersion,  LIB), Int32, (Ptr{UInt32},), maj))
    chk(ccall((:DAQmxGetSysNIDAQMinorVersion,  LIB), Int32, (Ptr{UInt32},), mnr))
    chk(ccall((:DAQmxGetSysNIDAQUpdateVersion, LIB), Int32, (Ptr{UInt32},), upd))
    return (Int(maj[]), Int(mnr[]), Int(upd[]))
end

function product_type(dev::AbstractString)
    buf = zeros(UInt8, 256)
    chk(ccall((:DAQmxGetDevProductType, LIB), Int32,
              (Cstring, Ptr{UInt8}, UInt32), dev, buf, UInt32(length(buf))))
    return GC.@preserve buf unsafe_string(pointer(buf))
end

function serial_number(dev::AbstractString)
    sn = Ref{UInt32}(0)
    chk(ccall((:DAQmxGetDevSerialNum, LIB), Int32,
              (Cstring, Ptr{UInt32}), dev, sn))
    return sn[]
end

for (fname, cfun) in ((:ai_channels, :DAQmxGetDevAIPhysicalChans),
                      (:ao_channels, :DAQmxGetDevAOPhysicalChans),
                      (:do_lines,    :DAQmxGetDevDOLines),
                      (:terminals,   :DAQmxGetDevTerminals))
    @eval function $fname(dev::AbstractString)
        buf = zeros(UInt8, 8192)
        chk(ccall(($(QuoteNode(cfun)), LIB), Int32,
                  (Cstring, Ptr{UInt8}, UInt32), dev, buf, UInt32(length(buf))))
        return _splitlist(GC.@preserve buf unsafe_string(pointer(buf)))
    end
end

self_test(dev::AbstractString) =
    chk(ccall((:DAQmxSelfTestDevice, LIB), Int32, (Cstring,), dev))
reset_device(dev::AbstractString) =
    chk(ccall((:DAQmxResetDevice, LIB), Int32, (Cstring,), dev))

# ---- cycle de vie d'une tâche --------------------------------------
function create_task(name::AbstractString = "")
    th = Ref{TaskHandle}(C_NULL)
    chk(ccall((:DAQmxCreateTask, LIB), Int32,
              (Cstring, Ptr{TaskHandle}), name, th))
    return th[]
end

start_task(th) = chk(ccall((:DAQmxStartTask, LIB), Int32, (TaskHandle,), th))
stop_task(th)  = chk(ccall((:DAQmxStopTask,  LIB), Int32, (TaskHandle,), th))
clear_task(th) = chk(ccall((:DAQmxClearTask, LIB), Int32, (TaskHandle,), th))

"""
    withtask(f, name="")

Crée une tâche, la passe à `f`, et garantit son arrêt et sa libération
même si `f` lève. À utiliser systématiquement : une tâche non libérée
garde la ressource matérielle verrouillée jusqu'au redémarrage du REPL.
"""
function withtask(f, name::AbstractString = "")
    th = create_task(name)
    try
        return f(th)
    finally
        try; stop_task(th); catch; end
        try; clear_task(th); catch; end
    end
end

# ---- déclaration de voies ------------------------------------------
function add_ao_voltage(th, chans::AbstractString; minv = -10.0, maxv = 10.0)
    chk(ccall((:DAQmxCreateAOVoltageChan, LIB), Int32,
              (TaskHandle, Cstring, Cstring, Float64, Float64, Int32, Cstring),
              th, chans, "", Float64(minv), Float64(maxv), Val_Volts, ""))
end

function add_ai_voltage(th, chans::AbstractString; minv = -10.0, maxv = 10.0,
                        termcfg = Val_Cfg_Default)
    chk(ccall((:DAQmxCreateAIVoltageChan, LIB), Int32,
              (TaskHandle, Cstring, Cstring, Int32, Float64, Float64, Int32, Cstring),
              th, chans, "", Int32(termcfg),
              Float64(minv), Float64(maxv), Val_Volts, ""))
end

function add_do(th, lines::AbstractString; grouping = Val_ChanForAllLines)
    chk(ccall((:DAQmxCreateDOChan, LIB), Int32,
              (TaskHandle, Cstring, Cstring, Int32),
              th, lines, "", Int32(grouping)))
end

"""Couplage AC/DC par voie — uniquement 611x et 6120."""
function set_ai_coupling(th, chan::AbstractString, coupling)
    chk(ccall((:DAQmxSetAICoupling, LIB), Int32,
              (TaskHandle, Cstring, Int32), th, chan, Int32(coupling)))
end

"""Plage réellement retenue par le pilote après coercition."""
function get_ai_max(th, chan::AbstractString)
    v = Ref{Float64}(0.0)
    chk(ccall((:DAQmxGetAIMax, LIB), Int32,
              (TaskHandle, Cstring, Ptr{Float64}), th, chan, v))
    return v[]
end

function cfg_sample_clock(th, rate::Real; source::AbstractString = "",
                          edge = Val_Rising, mode = Val_FiniteSamps,
                          nsamp::Integer = 1000)
    chk(ccall((:DAQmxCfgSampClkTiming, LIB), Int32,
              (TaskHandle, Cstring, Float64, Int32, Int32, UInt64),
              th, source, Float64(rate), Int32(edge), Int32(mode), UInt64(nsamp)))
end

# ---- écriture / lecture --------------------------------------------
function write_analog(th, data::Array{Float64}; nsamp_per_chan::Integer,
                      autostart::Bool = false, timeout = 10.0,
                      layout = Val_GroupByChannel)
    written = Ref{Int32}(0)
    chk(ccall((:DAQmxWriteAnalogF64, LIB), Int32,
              (TaskHandle, Int32, UInt32, Float64, UInt32,
               Ptr{Float64}, Ptr{Int32}, Ptr{UInt32}),
              th, Int32(nsamp_per_chan), UInt32(autostart), Float64(timeout),
              UInt32(layout), data, written, C_NULL))
    return Int(written[])
end

"""
    read_analog(th, nsamp, nchan) -> Matrix{Float64}

Renvoie une matrice `nsamp × nchan` : une colonne par voie, dans
l'ordre de déclaration.
"""
function read_analog(th, nsamp::Integer, nchan::Integer; timeout = 10.0)
    buf  = zeros(Float64, nsamp * nchan)
    nred = Ref{Int32}(0)
    chk(ccall((:DAQmxReadAnalogF64, LIB), Int32,
              (TaskHandle, Int32, Float64, UInt32, Ptr{Float64},
               UInt32, Ptr{Int32}, Ptr{UInt32}),
              th, Int32(nsamp), Float64(timeout), UInt32(Val_GroupByChannel),
              buf, UInt32(length(buf)), nred, C_NULL))
    return reshape(buf, Int(nsamp), Int(nchan))[1:Int(nred[]), :]
end

function write_do(th, values::Vector{UInt8}; autostart::Bool = true, timeout = 10.0)
    written = Ref{Int32}(0)
    chk(ccall((:DAQmxWriteDigitalLines, LIB), Int32,
              (TaskHandle, Int32, UInt32, Float64, UInt32,
               Ptr{UInt8}, Ptr{Int32}, Ptr{UInt32}),
              th, Int32(1), UInt32(autostart), Float64(timeout),
              UInt32(Val_GroupByChannel), values, written, C_NULL))
    return Int(written[])
end

# ---- raccourcis de haut niveau -------------------------------------
"""
    ai_once(chans, nchan; kw...) -> Vector{Float64}

Une mesure logicielle immédiate, sans horloge matérielle.
"""
function ai_once(chans::AbstractString, nchan::Integer; minv = -10.0, maxv = 10.0,
                 termcfg = Val_Cfg_Default, coupling = nothing)
    withtask("ai_once") do th
        add_ai_voltage(th, chans; minv, maxv, termcfg)
        # "" = toutes les voies de la tâche
        coupling === nothing || set_ai_coupling(th, "", coupling)
        return vec(read_analog(th, 1, nchan))
    end
end

"""
    ai_block(chans, nchan, rate, nsamp; kw...) -> Matrix{Float64}

Acquisition finie cadencée par l'horloge matérielle de la carte.
"""
function ai_block(chans::AbstractString, nchan::Integer, rate::Real, nsamp::Integer;
                  minv = -10.0, maxv = 10.0, termcfg = Val_Cfg_Default,
                  coupling = nothing)
    withtask("ai_block") do th
        add_ai_voltage(th, chans; minv, maxv, termcfg)
        coupling === nothing || set_ai_coupling(th, "", coupling)
        cfg_sample_clock(th, rate; mode = Val_FiniteSamps, nsamp = nsamp)
        start_task(th)
        return read_analog(th, nsamp, nchan; timeout = 5.0 + nsamp / rate)
    end
end

"""
    ao_hold(chans, volts) -> TaskHandle

Écrit une tension continue et **laisse la tâche active** pour que la
sortie soit maintenue. À libérer explicitement avec `clear_task`.
"""
function ao_hold(chans::AbstractString, volts::Vector{Float64};
                 minv = -10.0, maxv = 10.0)
    th = create_task("ao_hold")
    try
        add_ao_voltage(th, chans; minv, maxv)
        write_analog(th, volts; nsamp_per_chan = 1, autostart = true)
        return th
    catch
        try; clear_task(th); catch; end
        rethrow()
    end
end

end # module
