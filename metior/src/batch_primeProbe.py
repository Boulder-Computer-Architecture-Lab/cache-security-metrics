import copy 
import primeProbe
import argparse
import random
import json
import sys
import os
from caches.mirage import mirageCache
from caches.scatterCache import scatterCache
from caches.setAssocBitPLRUCache import setAssocBitPLRUCache
from caches.setAssocRandomCache import setAssocRandomCache
# from caches.skewedCeaserCache import skewedCeaserCache
from caches.setAssocRRCache import setAssocRRCache
from caches.setAssocFIFOCache import setAssocFIFOCache
from caches.setAssocMRUCache import setAssocMRUCache
from caches.skewedCache import skewedCache
from caches.setAssocLRUCache import setAssocLRUCache
from caches.setAssocBIPCache import setAssocBIPCache
from caches.setAssocBRRIPCache import setAssocBRRIPCache
from caches.setAssocTreePLRUCache import setAssocTreePLRUCache
from caches.mirageRR import mirageRRCache
from caches.wayPartLRUCache import wayPartLRUCache
from dag import dag_to_dict, unique_addr

caches = {
    "mirage": mirageCache,
    "scattercache": scatterCache,
    "setAssocBitPLRU": setAssocBitPLRUCache,
    "setAssocRR": setAssocRRCache,
    "setAssocFIFO": setAssocFIFOCache,
    "setAssocMRU": setAssocMRUCache,
    "skewed": skewedCache,
    "setAssocLRU": setAssocLRUCache,
    "setAssocBIP": setAssocBIPCache,
    "setAssocBRRIP": setAssocBRRIPCache ,
    "setAssocRandom": setAssocRandomCache,
    "setAssocTreePLRU": setAssocTreePLRUCache,
    "mirageRR": mirageRRCache,
    "wayPartLRU", wayPartLRUCache
}

def output_config_info(args):
    
    config_info = dict()
    
    ## output cache config 
    config_info["cacheType"] = args['cacheType'] 
    config_info["numLines"] =  args['numLines']

    config_info["associativity"] = args['associativity']
    config_info["sameset"] = args['sameset']

    ## output signaling config
    #config_info["numVicAcc"] = args["numVicAcc"]
    config_info["victDAG"] = args["victDAG"]
    config_info["subSectionLines"] = args["subSectionLines"]
    config_info["numPrime"] = args["numPrime"]
    
    config_info["total_samples"] = 0
    
    config_info["local_miss_array_dict"] = dict() 
    
    config_info["local_cost_dict"] = dict() 

    return config_info

def main(args):
    cacheType = args['cacheType']
    
    cache_kwargs = dict(
        numLines=args['numLines'], 
        associativity=args['associativity'],
        lineSize=args['lineSize'],
    )

    match cacheType:
        case "mirage" | "mirageRR":
            # Mirage
            mirage_kwargs = dict(
                numExtraPerSet=args['numExtraPerSet'], 
                debug=args['debug']
            )
            cache_kwargs |= mirage_kwargs
        case "scattercache": 
            # ScatterCache
            scattercache_kwargs = dict(
                numHG=args['numHG'], 
                debug=args['debug']
            )
            cache_kwargs |= scattercache_kwargs
        case "skewed":
            skewed_kwargs = dict(
               numHG=args['numHG'],
             )
            cache_kwargs |= skewed_kwargs
 
    cache = caches[cacheType](
        **cache_kwargs
    )
    
    config_info = output_config_info(args)

    if "victDict" in args.keys():
            victim_dict = args["victDict"]
    else:
        victDAGfile = args["victDAG"]
        victim_dict = dag_to_dict(victDAGfile)

    attacker_dict = None
    if "attackerDict" in args.keys():
        attacker_dict = args["attackerDict"]

    if(attacker_dict is None): 
        random.seed(0)
        local_miss_array = []
        local_cost = 0
        local_miss_array, local_cost, local_prime_array = primeProbe.warmup_then_attack(cache, args['subSectionLines'],\
                                                                        victim_dict, args['numPrime'],\
                                                                        int(args['iterations']), args['sameset'],\
                                                                        args['flush'], args['randomPrime'], args['debug'])

        config_info["local_miss_array_dict"] = local_miss_array
        config_info["local_cost_dict"] = local_cost
        config_info["local_prime_array"] = local_prime_array

        config_info["total_samples"] = args['iterations']

        return local_miss_array, unique_addr(victim_dict)
    else:
        local_miss_array = []
        local_cost = 0
        local_miss_array, local_cost, local_prime_array = primeProbe.warmup_then_attack_custom(cache, attacker_dict,\
                                                                        victim_dict, args['numPrime'],\
                                                                        int(args['iterations']), args['sameset'],\
                                                                        args['flush'], args['randomPrime'], args['debug'])

        config_info["local_miss_array_dict"] = local_miss_array
        config_info["local_cost_dict"] = local_cost
        config_info["local_prime_array"] = local_prime_array

        config_info["total_samples"] = args['iterations']

        return local_miss_array, unique_addr(victim_dict)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='')
    parser.add_argument('--numLines', dest='numLines', type=int, default=128, action="store",
            help='number of Lines (default: 128)')
    parser.add_argument('--associativity', dest='associativity', type=int, default=8, action="store",
            help='associativity (default: 8)')
    parser.add_argument('--lineSize', dest='lineSize', type=int, default=64, action="store",
            help='lineSize (default: 64)')

    parser.add_argument('--cacheType', dest='cacheType', type=str, action="store")
    parser.add_argument('--numExtraPerSet', dest='numExtraPerSet', type=int, default=8, action="store",
            help='numExtraPerSet if mirage')
    parser.add_argument('--numHG', dest='numHG', type=int, default=8, action="store",
            help='numHG if scatterCache')

    parser.add_argument('--sameset', dest='sameset', type=int, default=0, action="store",
            help='whether to (attempt) to use the same set during priming')
    parser.add_argument('--flush', dest='flush', type=int, default=1, action="store",
            help='whether to flush between P/P iterations')
    parser.add_argument('--randomVictim', dest='randomVictim', type=int, default=0, action="store",
            help='whether to randomize victim accesses between P/P iterations')
    parser.add_argument('--randomPrime', dest='randomPrime', type=int, default=0, action="store",
            help='whether to randomize prime/probe accesses between P/P iterations')

    parser.add_argument('--numVicAcc', dest='numVicAcc', type=int, default=0, action="store",
            help='number of victim accesses (default: 0)')
    parser.add_argument('--victDAG', dest='victDAG', default=0, action="store",
            help='Victim DAG to simulate')
    parser.add_argument('--subSectionLines', dest='subSectionLines', type=int, default=64, action="store",
            help='subSectionLines (default: 64)')
    parser.add_argument('--numPrime', dest='numPrime', type=int, default=1, action="store",
            help='numPrime(default: 1)')


    parser.add_argument('--randomSeed', dest='randomSeed', type=int, default=1, action="store",
            help='randomSeed (default: 1)')

    parser.add_argument('--output_dir', dest='output_dir', default="data", action="store",
            help='The output directory for csv files')

    parser.add_argument('--output_name', dest='file_name', default="out.json", action="store",
            help='The output file name')
    
    parser.add_argument('--iterations', dest='iterations', default="100", action="store",
            help='number of iterations')

    parser.add_argument('--debug', dest='debug', type=int, default=0, action="store",
            help='debug prints')

    args = vars(parser.parse_args())
    main(args)
