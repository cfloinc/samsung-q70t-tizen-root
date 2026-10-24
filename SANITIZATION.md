# Sanitization notes

This public copy was produced from a private working repository. Everything
below was replaced or removed before publishing.

## Redacted

| Kind | Private value | Public placeholder |
|---|---|---|
| TV address | a LAN IPv4 address | `<TV_IP>` |
| Control host | a LAN IPv4 address | `<HOST_IP>` |
| DNS resolver | a LAN IPv4 address | `<DNS_IP>` |
| Device DUID | 13-char device id | `<DUID>` |
| TVkey device id | 16-hex id | `<TVKEY_ID>` |
| Serial number | panel serial | `<SERIAL>` |
| Contact-Samsung unique id | 13-char id | `<UNIQUE_ID>` |
| Home directory | `/Users/<name>/…` | `<HOME>` / `<REPO>` |
| Local username | macOS account | `<user>` |

## Removed entirely

* Samsung firmware images and containers (`*.msd`, kernel dumps).
* Build outputs, disk images, signed packages, compiled payloads.
* Signing material and secrets (certificates, `.pwd`, tokens, SSH keys).
* Nested third-party git checkouts and vendored upstream releases.
* Session transcripts, screenshots, and anything captured from the TV's screen.

## Scripts

The published tooling reads addresses from the environment:

```sh
export TV_IP=192.0.2.10      # your TV
export HOST_IP=192.0.2.20    # the machine running the listener
```

## Re-check before publishing

```sh
# no private IPv4 literals
git grep -nIE '\b(10|172\.(1[6-9]|2[0-9]|3[01])|192\.168)\.[0-9]+\.[0-9]+'
# no MAC addresses
git grep -nIE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}'
# no home paths or usernames
git grep -nI '/Users/\|/home/[a-z]'
# no secrets
git ls-files | grep -iE '\.p12$|\.pfx$|\.pwd$|\.pem$|id_rsa|id_ed25519|token'
# no firmware / large binaries
git ls-files | grep -iE '\.(msd|img|tpk|wgt|so|elf|dll|exe)$'
```

Placeholders like `<TV_IP>` are intentional and match the first pattern only if
you fill them in with a real address — do not.
