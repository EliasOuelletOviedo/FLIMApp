"""
path_utils.jl

Shared path and picker helpers used by GUI and handlers.

Responsibilities:
- Handle file/folder picker failures safely
- Read/write path cache files
- Convert full paths to short display names
"""

"""
    pick_non_empty_path(picker::Function; error_msg::AbstractString)::Union{String, Nothing}

Execute a native picker and return a non-empty selected path, or `nothing`.
"""
function pick_non_empty_path(picker::Function; error_msg::AbstractString)::Union{String, Nothing}
    selected = try
        picker()
    catch e
        @warn String(error_msg) error=string(e)
        nothing
    end

    if selected === nothing
        return nothing
    end

    path = String(selected)
    return isempty(strip(path)) ? nothing : path
end

"""
    open_irf_dialog()::Union{String, Nothing}

Open a file picker for IRF selection.
"""
function open_irf_dialog()::Union{String, Nothing}
    return pick_non_empty_path(pick_file; error_msg="IRF file dialog failed")
end

"""
    open_folder_dialog()::Union{String, Nothing}

Open a folder picker for data-root selection.
"""
function open_folder_dialog()::Union{String, Nothing}
    return pick_non_empty_path(pick_folder; error_msg="Folder dialog failed")
end

"""
    set_path_cache!(cache_path::AbstractString, path_value::AbstractString)

Write an absolute path value to the provided cache file.
"""
function set_path_cache!(cache_path::AbstractString, path_value::AbstractString)
    mkpath(dirname(cache_path))
    open(cache_path, "w") do io
        write(io, String(path_value))
    end
    return nothing
end

"""
    update_path_textbox!(textbox, full_path::AbstractString)

Update a path textbox with only the basename for display.
"""
function update_path_textbox!(textbox, full_path::AbstractString)
    short_name = basename(String(full_path))
    textbox.displayed_string[] = short_name
    textbox.stored_string[] = short_name
    return nothing
end

"""
    cached_basename(cache_path::AbstractString; fallback_path::Union{Nothing, AbstractString}=nothing)::String

Read a cached full path and return only the filename/folder name for UI display.
Falls back to `fallback_path` when cache is missing or empty.
"""
function cached_basename(cache_path::AbstractString; fallback_path::Union{Nothing, AbstractString}=nothing)::String
    path_value = ""

    if isfile(cache_path)
        path_value = try
            strip(open(f -> read(f, String), cache_path))
        catch
            ""
        end
    end

    if isempty(path_value) && fallback_path !== nothing
        path_value = strip(String(fallback_path))
    end

    if isempty(path_value)
        return ""
    end

    return splitpath(path_value)[end]
end
