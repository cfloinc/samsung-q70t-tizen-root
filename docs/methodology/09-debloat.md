# 09 — Debloat mechanisms, ranked by durability

Measured on Tizen 6.0 / 2020 NIKEM. Other generations differ.

| Mechanism | Survives reboot? | Notes |
|---|---|---|
| Vendor `ConditionPathExists` marker in `/opt/usr/share/systemd/system/` | ✅ | Only for units that ship the condition. Creating the file **disables** the unit. |
| `pkgcmd -D -t app -n <pkg> --uid 5001` | ✅ (re-apply if flags revert) | Deactivates for the user; nothing is uninstalled. |
| `/run/systemd/system/<unit> → /dev/null` | ✅ **if re-applied** | `/run` is first in `UnitPath`, writable, tmpfs. |
| `systemctl mask` | ❌ | `/etc/systemd/system` is read-only even for root. |
| `systemctl disable` | ❌ | Vendor targets / path units / D-Bus re-activate "disabled" services. |
| `pkgcmd -u` on preloads | ❌ | `Operation not allowed [-4]`. |

## Practical recipe

1. **Markers** for every unit whose file contains
   `ConditionPathExists=!/opt/usr/share/systemd/system/<name>`.
2. **`/run` masks** for the rest, re-created by a boot hook.
3. **`--no-block` stops**, then a delayed second pass (~30 s) for anything that
   started before the masks landed.
4. **`pkgcmd -D`** for optional apps you can live without.

`systemctl stop` can hang indefinitely on this TV when the job touches a D-state
unit. Always:

```sh
systemctl --no-block stop <unit>
```

## A hosts-file backstop for DNS filtering

`/etc` is read-only, but a bind mount over `/etc/hosts` works with root and
survives only until reboot — so apply it from the boot hook:

```sh
mount --bind /opt/usr/share/tvroot/hosts.block /etc/hosts
```

`hosts.block` resolves ad/ACR domains to `0.0.0.0`, so the block still applies if
an app bypasses your resolver. Keep the list short and conservative: a wrong
entry can break account or app sign-in, and `/etc/hosts` is consulted before DNS.

## Measuring success

Use **service state, mask count, and free memory** — not load average. Roughly
ten processes sit in uninterruptible `D` state waiting on absent tuner hardware,
so idle load stays around 11–15 regardless of CPU work.

## Restore

Delete the markers, remove the `/run` masks (or reboot), and
`pkgcmd -A -t app -n <pkg> --uid 5001` for each deactivated app.
