# shellcheck shell=sh
if [ -n "${PS1:-}" ] || [ -n "${SSH_TTY:-}" ]; then
    if tty -s 2>/dev/null; then
        export GPG_TTY="$(tty)"
        gpg-connect-agent updatestartuptty /bye >/dev/null 2>&1 || true
    fi
fi
