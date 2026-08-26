#!/usr/bin/env bash

mkdir -p "$PWD/results/16kb"

./cachefx -v AES -c configs/cl256/w16/setassoc_lru.xml -m entropy -a occupancy -o "$PWD/results/16kb/setassoc_lru.csv" &
./cachefx -v AES -c configs/cl256/w16/setassoc_treeplru.xml -m entropy -a occupancy -o "$PWD/results/16kb/setassoc_treeplru.csv" &
./cachefx -v AES -c configs/cl256/w16/setassoc_rand.xml -m entropy -a occupancy -o "$PWD/results/16kb/setassoc_rand.csv" &
./cachefx -v AES -c configs/cl256/w16/scattercache.xml -m entropy -a occupancy -o "$PWD/results/16kb/scattercache.csv" &
./cachefx -v AES -c configs/cl256/w16/wpcache_lru.xml -m entropy -a occupancy -o "$PWD/results/16kb/wpcache_lru.csv" &
./cachefx -v AES -c configs/cl256/assoc_lru.xml -m entropy -a occupancy -o "$PWD/results/16kb/assoc_lru.csv" &
./cachefx -v AES -c configs/cl256/w16/setassoc_brrip.xml -m entropy -a occupancy -o "$PWD/results/16kb/setassoc_brrip.csv" &
./cachefx -v AES -c configs/cl256/w16/setassoc_bip.xml -m entropy -a occupancy -o "$PWD/results/16kb/setassoc_bip.csv" &
./cachefx -v AES -c configs/cl256/w16/setassoc_fifo.xml -m entropy -a occupancy -o "$PWD/results/16kb/setassoc_fifo.csv" &
./cachefx -v AES -c configs/cl256/w16/setassoc_rr.xml -m entropy -a occupancy -o "$PWD/results/16kb/setassoc_rr.csv" &
./cachefx -v AES -c configs/cl256/w16/skewed_lru.xml -m entropy -a occupancy -o "$PWD/results/16kb/skewed_lru.csv" &
./cachefx -v AES -c configs/cl256/w16/sasscache.xml -m entropy -a occupancy -o "$PWD/results/16kb/sasscache.csv" &
./cachefx -v AES -c configs/cl256/w16/setassoc_mru.xml -m entropy -a occupancy -o "$PWD/results/16kb/setassoc_mru.csv" &
./cachefx -v AES -c configs/cl256/w16/mirage.xml -m entropy -a occupancy -o "$PWD/results/16kb/mirage.csv" &

wait

echo "All 16KB CacheFX runs finished."