# Interactive-shell Wayland/Pulse exports — some shells (non-login fish)
# skip pam_env, so /etc/environment alone isn't enough. Keep values in
# sync with /etc/environment + mybox.nspawn.

export DISPLAY="${DISPLAY:-:0}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-/run/host/wayland-1}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
export PULSE_SERVER="${PULSE_SERVER:-unix:/run/host/pulse/native}"
export XDG_SESSION_TYPE="${XDG_SESSION_TYPE:-wayland}"
