# Probability of Attack Success

This is a custom framework based on the paper "How secure is your cache against side-channel attacks?" by He and Lee.

The following snippet shows how to use the PAS framework.

```bash
usage: pas.py [-h] [--type {set-assoc,skewed,scattercache,way-part,sass}] [--assoc ASSOC] [--size SIZE] [--parts PARTS] [--domains DOMAINS]

options:
  -h, --help            show this help message and exit
  --type {set-assoc,skewed,scattercache,way-part,sass}, -t {set-assoc,skewed,scattercache,way-part,sass}
  --assoc ASSOC, -a ASSOC
                        The associativity of the cache.
  --size SIZE, -s SIZE  The size of the cache.
  --parts PARTS, -p PARTS
                        The number of skews or partitions in the cache.
  --domains DOMAINS     The number of domains in the cache.
```