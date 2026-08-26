#!/usr/bin/env bash

mkdir -p "$PWD/results/128kb"

./cachefx -v AES -c configs/cl2048/w16/setassoc_lru.xml -m entropy -a occupancy -o "$PWD/results/128kb/setassoc_lru.csv" &
./cachefx -v AES -c configs/cl2048/w16/setassoc_treeplru.xml -m entropy -a occupancy -o "$PWD/results/128kb/setassoc_treeplru.csv" &
./cachefx -v AES -c configs/cl2048/w16/setassoc_rand.xml -m entropy -a occupancy -o "$PWD/results/128kb/setassoc_rand.csv" &
./cachefx -v AES -c configs/cl2048/w16/scattercache.xml -m entropy -a occupancy -o "$PWD/results/128kb/scattercache.csv" &
./cachefx -v AES -c configs/cl2048/w16/wpcache_lru.xml -m entropy -a occupancy -o "$PWD/results/128kb/wpcache_lru.csv" &
./cachefx -v AES -c configs/cl2048/assoc_lru.xml -m entropy -a occupancy -o "$PWD/results/128kb/assoc_lru.csv" &
./cachefx -v AES -c configs/cl2048/w16/setassoc_brrip.xml -m entropy -a occupancy -o "$PWD/results/128kb/setassoc_brrip.csv" &
./cachefx -v AES -c configs/cl2048/w16/setassoc_bip.xml -m entropy -a occupancy -o "$PWD/results/128kb/setassoc_bip.csv" &
./cachefx -v AES -c configs/cl2048/w16/setassoc_fifo.xml -m entropy -a occupancy -o "$PWD/results/128kb/setassoc_fifo.csv" &
./cachefx -v AES -c configs/cl2048/w16/setassoc_rr.xml -m entropy -a occupancy -o "$PWD/results/128kb/setassoc_rr.csv" &
./cachefx -v AES -c configs/cl2048/w16/skewed_lru.xml -m entropy -a occupancy -o "$PWD/results/128kb/skewed_lru.csv" &
./cachefx -v AES -c configs/cl2048/w16/sasscache.xml -m entropy -a occupancy -o "$PWD/results/128kb/sasscache.csv" &
./cachefx -v AES -c configs/cl2048/w16/setassoc_mru.xml -m entropy -a occupancy -o "$PWD/results/128kb/setassoc_mru.csv" &
./cachefx -v AES -c configs/cl2048/w16/mirage.xml -m entropy -a occupancy -o "$PWD/results/128kb/mirage.csv" &

wait

echo "All 128kb CacheFX runs finished."