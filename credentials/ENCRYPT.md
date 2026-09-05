# Turning these into stageable .cred files

Every file beside this one is **plaintext**, for reading and editing. None
of them can go on an ESP as-is — see README.md, a plaintext .cred breaks the
boot. Encrypt each one you want first:

    for f in ssh.authorized_keys.root passwd.hashed-password.root \
             tmpfiles.extra network.dns sysusers.extra home.create.alan; do
        [ -f "$f" ] || continue
        sudo systemd-creds encrypt --with-key=null --name="$f" "$f" "$f.cred"
    done

`--name=` must match the filename minus `.cred`, or the credential is
imported under the wrong name and silently ignored.

Then stage the `.cred` files as README.md describes. Keep the plaintext
originals out of the ESP.
