#!/usr/bin/env bash

mkdir -p "$PWD/results/32kb"

./cachefx -v AES -c configs/cl512/w16/setassoc_lru.xml -m entropy -a occupancy -o "$PWD/results/32kb/setassoc_lru.csv" &
./cachefx -v AES -c configs/cl512/w16/setassoc_treeplru.xml -m entropy -a occupancy -o "$PWD/results/32kb/setassoc_treeplru.csv" &
./cachefx -v AES -c configs/cl512/w16/setassoc_rand.xml -m entropy -a occupancy -o "$PWD/results/32kb/setassoc_rand.csv" &
./cachefx -v AES -c configs/cl512/w16/scattercache.xml -m entropy -a occupancy -o "$PWD/results/32kb/scattercache.csv" &
./cachefx -v AES -c configs/cl512/w16/wpcache_lru.xml -m entropy -a occupancy -o "$PWD/results/32kb/wpcache_lru.csv" &
./cachefx -v AES -c configs/cl512/assoc_lru.xml -m entropy -a occupancy -o "$PWD/results/32kb/assoc_lru.csv" &
./cachefx -v AES -c configs/cl512/w16/setassoc_brrip.xml -m entropy -a occupancy -o "$PWD/results/32kb/setassoc_brrip.csv" &
./cachefx -v AES -c configs/cl512/w16/setassoc_bip.xml -m entropy -a occupancy -o "$PWD/results/32kb/setassoc_bip.csv" &
./cachefx -v AES -c configs/cl512/w16/setassoc_fifo.xml -m entropy -a occupancy -o "$PWD/results/32kb/setassoc_fifo.csv" &
./cachefx -v AES -c configs/cl512/w16/setassoc_rr.xml -m entropy -a occupancy -o "$PWD/results/32kb/setassoc_rr.csv" &
./cachefx -v AES -c configs/cl512/w16/skewed_lru.xml -m entropy -a occupancy -o "$PWD/results/32kb/skewed_lru.csv" &
./cachefx -v AES -c configs/cl512/w16/sasscache.xml -m entropy -a occupancy -o "$PWD/results/32kb/sasscache.csv" &
./cachefx -v AES -c configs/cl512/w16/setassoc_mru.xml -m entropy -a occupancy -o "$PWD/results/32kb/setassoc_mru.csv" &
./cachefx -v AES -c configs/cl512/w16/mirage.xml -m entropy -a occupancy -o "$PWD/results/32kb/mirage.csv" &

wait

echo "All 32KB CacheFX runs finished."