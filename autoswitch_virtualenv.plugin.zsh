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


function _python_version() {
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


function _maybeworkon() {
    local virtualenv_dir="$1"
    local virtualenv_type="$2"
    local virtualenv_name="$(_get_virtualenv_name $virtualenv_dir $virtualenv_type)"

    local DEFAULT_MESSAGE_FORMAT="Switching %virtualenv_type: ${BOLD}${PURPLE}%virtualenv_name${NORMAL} ${GREEN}[🐍%py_version]${NORMAL}"
    if [[ "$LANG" != *".UTF-8" ]]; then
        # remove multibyte characters if the terminal does not support utf-8
        DEFAULT_MESSAGE_FORMAT="${DEFAULT_MESSAGE_FORMAT/🐍/}"
    fi

    # don't reactivate an already activated virtual environment
    if [[ -z "$VIRTUAL_ENV" || "$virtualenv_name" != "$(_get_virtualenv_name $VIRTUAL_ENV $virtualenv_type)" ]]; then
        if [[ ! -d "$virtualenv_dir" ]]; then
            printf "Unable to find ${PURPLE}$virtualenv_name${NORMAL} virtualenv\n"
            return
        fi

        local py_version="$(_python_version "$virtualenv_dir/bin/python")"
        local message="${AUTOSWITCH_MESSAGE_FORMAT:-"$DEFAULT_MESSAGE_FORMAT"}"
        message="${message//\%virtualenv_type/$virtualenv_type}"
        message="${message//\%virtualenv_name/$virtualenv_name}"
        message="${message//\%py_version/$py_version}"
        _autoswitch_message "${message}\n"

        # if we are using pipenv and activate its virtual environment - turn down its verbosity
        # to prevent users seeing " Pipenv found itself running within a virtual environment" warning
        if [[ "$virtualenv_type" == "pipenv" && "$PIPENV_VERBOSITY" != -1 ]]; then
            export PIPENV_VERBOSITY=-1
        fi

        # much faster to source the activate file directly rather than use the `workon` command
        _source_virtualenv "$virtualenv_dir"
    fi
}



function _activate_poetry() {
    # TODO: make this faster (slow when virtualenv dir is not local)
    # my initial idea is to set some file (maybe .venv, since this is already
    # .gitgnored, or maybe something else, like .autoswitch) in the root of the 
    # workdir, and then let that file point to the virtualenv dir.

    # check if any environments exist before trying to activate
    # if env list is empty, then no environment exists that can be activated
    local virtualenv_dir="$(poetry env list --full-path | sort -k 2 | tail -n 1 | cut -d' ' -f1)"
    if [[ -n "$virtualenv_dir" ]]; then
        _maybeworkon "$virtualenv_dir" "poetry"
        return 0
    fi
    return 1
}


function _activate_pipenv() {
    # TODO: make this faster (slow when virtualenv dir is not local)
    # my initial idea is to set some file (maybe .venv, since this is already
    # .gitgnored, or maybe something else, like .autoswitch) in the root of the 
    # workdir, and then let that file point to the virtualenv dir.

    # unfortunately running pipenv each time we are in a pipenv project directory is slow :(
    if virtualenv_dir="$(PIPENV_IGNORE_VIRTUALENVS=1 pipenv --venv 2>/dev/null)"; then
        _maybeworkon "$virtualenv_dir" "pipenv"
        return 0
    fi
    return 1
}


function _get_virtualenv_type() {
    # NOTE: We check virtualenv first because we can skip the fetching 
    # of the virtualenv directory (via pipenv/poetry) which can be slow,
    # this way speed is a lot more optimized. This also means if for some reason
    # there exists a virtualenv directory that is not the one associated with
    # pipenv/poetry, it takes priority

    local cur_dir="$1"
    if [[ -d "${cur_dir}/.env" || -d "${cur_dir}/.venv" || -d "${cur_dir}/env" || -d "${cur_dir}/venv" ]]; then
        printf "virtualenv"
    elif [[ -f "${cur_dir}/poetry.lock" ]]; then
        printf "poetry"
    elif [[ -f "${cur_dir}/Pipfile" ]]; then
        printf "pipenv"
    else
        printf "unknown"
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


function check_virtualenv() {
    local file_owner
    local file_permissions

    local work_dir="$(_find_first_ancestor "$PWD")"
    
    # if we are in a virtualenv project
    if [[ -n "$work_dir" ]]; then
        local virtualenv_type="$(_get_virtualenv_type "$work_dir")"

        # TODO: better security measures, maybe only activate if activate file
        # is owned by the user running the script?
        
        if [[ "$virtualenv_type" == "pipenv" ]]; then
            if type "pipenv" > /dev/null && _activate_pipenv; then
                return
            fi
        elif [[ "$virtualenv_type" == "poetry" ]]; then
            if type "poetry" > /dev/null && _activate_poetry; then
                return
            fi
        elif [[ "$virtualenv_type" == "virtualenv" ]]; then
            # TODO: repeated work, not a very clean pattern lol
            local virtualenv_dir
            if [[ -d "${work_dir}/.env" ]]; then
                virtualenv_dir="${work_dir}/.env"
            elif [[ -d "${work_dir}/.venv" ]]; then
                virtualenv_dir="${work_dir}/.venv"
            elif [[ -d "${work_dir}/env" ]]; then
                virtualenv_dir="${work_dir}/env"
            elif [[ -d "${work_dir}/venv" ]]; then
                virtualenv_dir="${work_dir}/venv"
            else
                printf "${RED}AUTOSWITCH ERROR: Could not locate virtualenv dir\n"
            fi
            _maybeworkon "$virtualenv_dir" "virtualenv"
            return
        else
            printf "${RED}AUTOSWITCH ERROR: Unknown virtualenv type: $virtualenv_type${NORMAL}\n"
        fi
    elif [[ -n "$VIRTUAL_ENV" ]]; then
        local virtualenv_type="$(_get_virtualenv_type "$OLDPWD")"
        local virtualenv_name="$(_get_virtualenv_name "$VIRTUAL_ENV" "$virtualenv_type")"
        _autoswitch_message "Deactivating: ${BOLD}${PURPLE}%s${NORMAL}\n" "$virtualenv_name"
        source deactivate
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
