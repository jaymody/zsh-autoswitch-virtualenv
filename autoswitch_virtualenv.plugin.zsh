export AUTOSWITCH_VERSION="3.4.0"           # version of autoswitch

# --- editable settings ---
# AUTOSWITCH_MESSAGE_FORMAT         # custom format of messages
# AUTOSWITCH_SILENT                 # if empty, show message, else don't show messages


RED="\e[31m"
GREEN="\e[32m"
PURPLE="\e[35m"
BOLD="\e[1m"
NORMAL="\e[0m"


function _source_virtualenv() {
    local virtualenv_dir="$1"
    local activate_script="$virtualenv_dir/bin/activate"

    if [[ "$activate_script" == *'..'* ]]; then
        (>&2 printf "AUTOSWITCH WARNING: ")
        (>&2 printf "target virtualenv contains invalid characters\n")
        (>&2 printf "virtualenv activation cancelled\n")
        return
    else
        source "$activate_script"
    fi
}


function _get_python_version() {
    local PYTHON_BIN="$1"
    if [[ -f "$PYTHON_BIN" ]] then
        # for some reason python --version writes to stderr
        printf "%s" "$($PYTHON_BIN --version 2>&1)"
    else
        printf "unknown"
    fi
}


function _autoswitch_message() {
    if [ -z "$AUTOSWITCH_SILENT" ]; then
        (>&2 printf "$@")
    fi
}


function _find_first_ancestor(){
    # input:
    #    $1 - path to a directory
    # returns:
    #    the first ancestor directory (including this one) that satisfies the condition:
    #       - has virtualenv (via a dir named env, venv, .env, or .venv)
    #       - has pipenv (via the existence of a file named Pipfile)
    #       - has poetry (via the existence of a file named poetry.lock)
    #    stops the search once either the root directory or home directory is reached,
    #    in which case the return will be None

    local cur_dir="$1"
    local virtualenv_type="$(_get_virtualenv_type "$cur_dir")"

    if [ "$virtualenv_type" != "unknown" ]; then
        printf "$cur_dir"
    else
        if [[ "$cur_dir" = "/" || "$cur_dir" = "$HOME" ]]; then
            return
        fi
        _find_first_ancestor "$(dirname "$cur_dir")"
    fi
}


function _get_virtualenv_type() {
    # NOTE: We check pyenv first so it get's priority such that we don't conflict
    # with their auto switching stuff via pyenv local.
    # 
    # We check virtualenv second because we can skip the fetching 
    # of the virtualenv directory (via pipenv/poetry) which can be slow,
    # this way speed is a lot more optimized. This also means if for some reason
    # there exists a virtualenv directory that is not the one associated with
    # pipenv/poetry, it takes priority

    local cur_dir="$1"
    if [[ -f "$cur_dir/.python-version" ]]; then
        printf "pyenv"
    elif [[ -f "${cur_dir}/.env/bin/activate" || -f "${cur_dir}/.venv/bin/activate" || -f "${cur_dir}/env/bin/activate" || -f "${cur_dir}/venv/bin/activate" ]]; then
        printf "virtualenv"
    elif [[ -f "${cur_dir}/poetry.lock" ]]; then
        printf "poetry"
    elif [[ -f "${cur_dir}/Pipfile" ]]; then
        printf "pipenv"
    else
        printf "unknown"
    fi  
}


function _get_virtualenv_dir() {
    # NOTE: if type is pyenv we simply return nothing (pyenv does it's own)
    # autoswitching
    local work_dir="$1"
    local virtualenv_type="$2"

    local virtualenv_dir
    if [[ "$virtualenv_type" == "pipenv" ]]; then
        # unfortunately running pipenv each time we are in a pipenv project directory is slow :(
        if type "pipenv" > /dev/null && _virtualenv_dir="$(PIPENV_IGNORE_VIRTUALENVS=1 pipenv --venv 2>/dev/null)"; then
            virtualenv_dir="$_virtualenv_dir"
        fi
    elif [[ "$virtualenv_type" == "poetry" ]]; then
        if type "poetry" > /dev/null && _virtualenv_dir="$(poetry env list --full-path | sort -k 2 | tail -n 1 | cut -d' ' -f1)"; then
            virtualenv_dir="$_virtualenv_dir"
        fi
    elif [[ "$virtualenv_type" == "virtualenv" ]]; then
        if [[ -f "${work_dir}/.env/bin/activate" ]]; then
            virtualenv_dir="${work_dir}/.env"
        elif [[ -f "${work_dir}/.venv/bin/activate" ]]; then
            virtualenv_dir="${work_dir}/.venv"
        elif [[ -f "${work_dir}/env/bin/activate" ]]; then
            virtualenv_dir="${work_dir}/env"
        elif [[ -f "${work_dir}/venv/bin/activate" ]]; then
            virtualenv_dir="${work_dir}/venv"
        fi
    fi

    # double check activate script exists, if not, we return nothing
    if [[ -f "${virtualenv_dir}/bin/activate" ]]; then
        printf "$virtualenv_dir"
    fi
}


function _get_virtualenv_name() {
    local virtualenv_dir="$1"
    local virtualenv_type="$2"
    local virtualenv_name="$(basename "$virtualenv_dir")"

    # clear pipenv from the extra identifiers at the end
    if [[ "$virtualenv_type" == "pipenv" ]]; then
        virtualenv_name="${virtualenv_name%-*}"
    fi

    printf "%s" "$virtualenv_name"
}


function check_virtualenv() {
    # TODO: better security measures, maybe only activate if activate file
    # is owned by the user running the script?

    local work_dir="$(_find_first_ancestor "$PWD")"
    local virtualenv_type="$(_get_virtualenv_type "$work_dir")"
    local virtualenv_dir="$(_get_virtualenv_dir "$work_dir" "$virtualenv_type")"
    local virtualenv_name="$(_get_virtualenv_name $work_dir $virtualenv_type)"

    local old_work_dir="$(_find_first_ancestor "$OLDPWD")"
    local old_virtualenv_type="$(_get_virtualenv_type "$old_work_dir")"
    local old_virtualenv_dir="$(_get_virtualenv_dir "$old_work_dir" "$old_virtualenv_type")"
    local old_virtualenv_name="$(_get_virtualenv_name $old_work_dir $old_virtualenv_type)"

    # printf "work_dir            = $work_dir\n"
    # printf "virtualenv_type     = $virtualenv_type\n"
    # printf "virtualenv_dir      = $virtualenv_dir\n"
    # printf "virtualenv_name     = $virtualenv_name\n"
    
    # if we are in a virtualenv project
    if [[ -d "$work_dir" && -d "$virtualenv_dir" ]]; then
        # Don't reactivate (i.e.) if the current virtual env == project virtualenv
        if [[ "$VIRTUAL_ENV" == "$virtualenv_dir" ]]; then
            return
        fi

        local py_version="$(_get_python_version "$virtualenv_dir/bin/python")"
        _autoswitch_message "Switching $virtualenv_type: ${BOLD}${PURPLE}$virtualenv_name${NORMAL} ${GREEN}[$py_version]${NORMAL}\n"

        # if we are using pipenv and activate its virtual environment - turn down its verbosity
        # to prevent users seeing " Pipenv found itself running within a virtual environment" warning
        if [[ "$virtualenv_type" == "pipenv" && "$PIPENV_VERBOSITY" != -1 ]]; then
            export PIPENV_VERBOSITY=-1
        fi

        # source activate file (faster than use the `workon` command)
        _source_virtualenv "$virtualenv_dir"
    # case where a virtualenv is active, but where are not in a virtualenv project
    elif [[ -n "$VIRTUAL_ENV" ]]; then
        if [[ -d "$old_work_dir" && -d "$old_virtualenv_dir" && "$VIRTUAL_ENV" == "$old_virtualenv_dir" ]]; then
            _autoswitch_message "Deactivating: ${BOLD}${PURPLE}%s${NORMAL}\n" "$old_virtualenv_name"
            deactivate
        fi
    else
        # do nothing
    fi
}


function enable_autoswitch_virtualenv() {
    disable_autoswitch_virtualenv
    add-zsh-hook chpwd check_virtualenv
}


function disable_autoswitch_virtualenv() {
    add-zsh-hook -D chpwd check_virtualenv
}

# This function is only used to startup zsh-autoswitch-virtualenv
# the first time a terminal is started up
# it waits for the terminal to be ready using precmd and then
# immediately removes itself from the zsh-hook.
# This seems important for "instant prompt" zsh themes like powerlevel10k
function _autoswitch_startup() {
    add-zsh-hook -D precmd _autoswitch_startup
    enable_autoswitch_virtualenv
    check_virtualenv
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd _autoswitch_startup
