from joblib import Parallel, delayed
import sys
import os

# Import off-path folders
currentPath = os.getcwd()

sys.path.append(currentPath + '/src/')
sys.path.append(currentPath + '/src/caches/') 
print(currentPath + '/src/cache-analysis/caches/')

import numpy as np
import json
import os
import matplotlib.pyplot as plt
from cacheObj import cacheObj
from leakageCalculator import *
from tqdm import tqdm
import itertools
from batch_primeProbe import main as primeprobe
from batch_primeProbe import caches

# ========== Experiment Parameters ==========

# The number of attacker priming steps
primingStepRange = [8] # [1,2,4,8] 
# The number of lines the attacker will prime/probe
primingRatioRange = np.arange(0,512,16) # np.arange(0,2048,16) 
# The number of accesses the *victim* will perform
numAccRangeRange = [np.arange(15,28)]
# The number of cache hash groups (only valid for skewed caches)
numHGRange = [1]

# ===========================================
import argparse

parser = argparse.ArgumentParser(description='')
parser.add_argument('--numLines', dest='numLines', type=int, default=128, action="store",
        help='number of Lines (default: 128)')
parser.add_argument('--associativity', dest='associativity', type=int, default=8, action="store",
        help='associativity (default: 8)') 
parser.add_argument('--cacheType', dest='cacheType', type=str, action="store", choices=caches.keys(),
        help='Type of cache')
        
parser.add_argument('--numExtraPerSet', dest='numExtraPerSet', type=int, default=8, action="store",
        help='numExtraPerSet if mirage')
parser.add_argument('--numHG', dest='numHG', type=int, default=8, action="store",
        help='numHG if skewedCache')
parser.add_argument(
        "--debug", action=argparse.BooleanOptionalAction, default=False
    )
parser.add_argument(
        "--out", "-o", type=str, help="Output file name", default="results"
    )
args = parser.parse_args()
print(json.dumps(vars(args), indent=4))

# ===========================================

# For a single experiment:
def singleSub(primingSteps, primingRatio, numAccRange, numHG):
    x2y = dict()
    y_set = set()

    for numAcc in numAccRange:
        victDict = {}
        for i in range(numAcc):
            victDict[i] = i * 64 + 100000000

        cache = cacheObj(None, victDict)
        cache.subSectionLines = primingRatio
        cache.numPrime = primingSteps
        cache.iterations = 5000
        
        cache.cacheType = args.cacheType
        cache.associativity = args.associativity
        cache.numExtraPerSet = args.numExtraPerSet
        cache.numHG = args.numHG
        cache.numLines = args.numLines
        cache.debug = args.debug

        y, x = primeprobe(cache.info())
        
        if x not in x2y.keys():
            x2y[x] = []

        x2y[x] = x2y[x] + y
        y_set = y_set.union(set(y))

        leakage = calculateLeakage(x2y, False)

    return leakage

# Print start time
import time

start = time.time()
# Construct list of possible experiments
experiments = []
for primes in primingStepRange:
    for ratio in primingRatioRange:
        for numAccRange in numAccRangeRange:
            for numHG in numHGRange:
                experiments.append((primes, ratio, numAccRange, numHG))

# Excute these experiments in parallel (using all CPUs)
leakage_arr = []
leakage_arr = Parallel(n_jobs=-1)(delayed(singleSub)(primes, ratio, numAccRange, numHG) for (primes, ratio, numAccRange, numHG) in tqdm(experiments))

df = pd.DataFrame(list(experiments), columns=["NumPrimes", "Ratio", "NumAcc", "numHG"])
df['Leakage'] = leakage_arr

df.to_pickle(currentPath + f"/{args.out}.pkl")

end = time.time()
elapsed_minutes = (end - start) / 60

print(f"Execution time: {elapsed_minutes:.4f} minutes")
print("Done!")
