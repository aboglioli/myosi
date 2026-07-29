# Interactive-shell Wayland / Pulse env exports.
#
# /etc/environment is read by pam_env but some shells (notably
# non-login fish) skip pam_env. /etc/profile.d/*.sh is sourced by
# every POSIX login shell, fish via the wrapper in
# /etc/profile.d/fish-foreign-env-loader. Keep values in sync with
# /etc/environment + mybox.nspawn.

export DISPLAY="${DISPLAY:-:0}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-/run/host/wayland-1}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
export PULSE_SERVER="${PULSE_SERVER:-unix:/run/host/pulse/native}"
export XDG_SESSION_TYPE="${XDG_SESSION_TYPE:-wayland}"
