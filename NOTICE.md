# Notice, provenance and credits

## What is deliberately not included

* No Samsung firmware images, update containers, kernels or extracted AES keys.
* No Samsung binaries (`sdb`, `dotnet-launcher`, `sdbd-tarlauncher`, …) and no
  copies of Samsung's own `profile.d` scripts.
* No device identifiers: serial numbers, DUIDs, TVkey IDs or MAC addresses.
* No network addresses beyond RFC1918 placeholders, and no host usernames or
  absolute home paths.
* No signing material: no `author.p12`, distributor certificates, `.pwd` files,
  tokens or SSH keys.

`persistent-hook/build-patch.py` builds a same-size patched copy of **your own**
vendor script; the vendor original is read locally and never redistributed.

## Prior art

This work would not exist without these projects and people:

* **[chris-ritsen/samsung-tv-root](https://github.com/chris-ritsen/samsung-tv-root)** —
  SDB injection foothold, archive-root, and the earliest public note that UEP is
  a separate boundary from `uid 0`.
* **[txtsamu/claude-research](https://github.com/txtsamu/claude-research)** —
  *Samsung TV UEP bypass and KantS2 root*: the analysis of UEP as a script
  *file-loading* hook, the `sh -c "$(cat …)"` bypass, and the `AUL_APPID`
  launcher contract. This is what finished the persistence work here.
* **metaljay / [tiz0wn #1](https://github.com/sebastianspicker/tiz0wn/issues/1)** —
  independent confirmation of the NIKEM gadget addresses, the UEP
  verifier-entry boot-loop warning, and the raw-block `profile.d` persistence
  technique.
* **Luminger's samsung-tv-usb-root** — the exFAT trigger construction and
  `ksymtab` scanning tooling.
* **[splitcipher/couchroot](https://github.com/splitcipher/couchroot)** — the
  QN90A audit establishing that `systemctl disable` does not stick and that
  `/run/systemd/system` masks do.
* **[berteotti/custom-tv](https://github.com/berteotti/custom-tv)** and
  **abhiigatty's Tizen 9 modding writeup** — the
  `ConditionPathExists` marker census and the `pkgcmd -D --uid 5001` idiom.
* **[Gathin23/cleanyourtv](https://github.com/Gathin23/cleanyourtv)** — public
  confirmation that package-disable flags re-enable themselves after some
  firmware actions, which is why the boot-time re-apply matters.
* Field reports in
  **[chris-ritsen/samsung-tv-root#5](https://github.com/chris-ritsen/samsung-tv-root/issues/5)** —
  preload packages cannot be uninstalled on Tizen 6.0; markers are the durable
  route.
* **[simbasjungles/free-my-tv](https://github.com/simbasjungles/free-my-tv)** —
  the launcher used on the TV itself.

If you believe something here misattributes your work, open an issue and it will
be corrected.
