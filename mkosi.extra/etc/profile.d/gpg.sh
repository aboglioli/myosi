# shellcheck shell=sh
if [ -n "${PS1:-}" ] || [ -n "${SSH_TTY:-}" ]; then
    if tty -s 2>/dev/null; then
        GPG_TTY="$(tty)"
        export GPG_TTY
        gpg-connect-agent updatestartuptty /bye >/dev/null 2>&1 || true
    fi
fi
