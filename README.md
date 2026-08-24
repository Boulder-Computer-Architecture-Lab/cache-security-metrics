# Cache Security Metrics

This repository cointains the files used for "SoK: All You Ever Wanted to Know About Cache Security Metrics".

## Organization

This repository is organized as follows:

```bash
.
├── cacheaudit
├── cachefx # contains CacheFX and UniSEC
├── metior
├── pas
└── README.md
```

## Changes Made to Artifacts

We make several modifications to the original metrics' artifacts which we outline here.

### CacheAudit

The following replacement policies were added to CacheAudit:

- Random
- BRRIP
- BIP
- Round Robin
- MRU

### CacheFX

The following replacement policies were added to CacheFX:
- MRU
- Round Robin
- FIFO

The following cache architectures were also added:
- Skewed Associative
- MIRAGE
- SassCache (adapted from [here](https://zenodo.org/records/16747907))

Additionally, the measurement of ESS from UniSEC was also added.

### Metior

The following replacement policies were added to Metior:
- BIP
- BRRIP
- FIFO
- MRU
- Random
- Round Robin
- Tree-PLRU

The following caches were added to Metior:
- ScatterCache
- SassCache
- Skewed Associative
- MIRAGE
- Way Partitioned

### PAS

We created a framework to derive the PAS probabilities based on [1].

## References

1. "CacheAudit: A Tool for the Static Analysis of Cache Side Channels" by Doychev et al.
2. [CacheAudit GitHub repository](https://github.com/cacheaudit/cacheaudit)
3. "CacheFX: A Framework for Evaluating Cache Security" by Genkin et al.
4. [CacheFX GitHub repository](https://github.com/0xADE1A1DE/CacheFX)
5. "UniSEC: A Unified Security Evaluation Framework for Secure Cache Architectures" by Shrestha et al.
6. "Metior: A Comprehensive Model to Evaluate Obfuscating Side-Channel Defense Schemes" by Deutsch et al.
7. [Metior Github repository](https://github.com/MATCHA-MIT/Metior)
8. "How secure is your cache against side-channel attacks?" by He and Lee
