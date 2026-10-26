# Target profiles

One file per device, containing **facts measured on that device only**. Use this
template:

```markdown
# <model> — <platform> — <year>

| Item | Value |
|---|---|
| Model | |
| Platform | |
| OS / kernel | |
| Firmware | |
| .NET runtime | |
| Rootfs | |
| Foothold | |
| Root path | |
| Persistence | |

## Measured facts
## Addresses (build-specific)
## What did not work
## References
```

A profile must state the firmware string next to any address table; addresses are
not portable across builds.

## Index

| Target | Platform | Year | Root path | Persistence |
|---|---|---|---|---|
| [QN65Q70TAFXZA](q70t-nikem-2020.md) | `20_NIKEM_QTV` | 2020 | exFAT USB kernel LPE | raw-block `profile.d` patch |
| [QN55Q90TAFXZC](q90t-nikem-2020.md) | `20_NIKEM_QTV` | 2020 | exFAT USB kernel LPE | raw-block `profile.d` patch (p18) |
