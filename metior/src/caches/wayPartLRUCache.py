import numpy as np
import sys

cache_debug = False
INVALID_TAG = -1
INT_MAX = sys.maxsize

class wayPartLRUCache:
    def __init__(self, numLines, associativity, lineSize, parts=None):
        self.numLines = numLines
        self.associativity = associativity
        self.lineSize = lineSize

        numSets = numLines // associativity

        self.tagStore = (
            np.ones((numSets, associativity), dtype=np.int32) * INVALID_TAG
        )
        self.LRUStore = np.zeros(
            (numSets, associativity),
            dtype=np.int32
        )

        self.clock = 0

        # Default: one partition per way
        if parts is None:
            self.parts = {
                way_id: [way_id]
                for way_id in range(associativity)
            }
        else:
            self.parts = parts

    def clearCache(self, debug=False):
        self.tagStore = np.ones((int(self.numLines/self.associativity), self.associativity), dtype=np.int32) * INVALID_TAG
        self.LRUStore = np.zeros((int(self.numLines/self.associativity), self.associativity), dtype=np.int32) 
        self.clock = 0

    def getTag(self, addr):
        return int(addr / (self.lineSize * (self.numLines / self.associativity)))

    def getSet(self, addr):
        return int((addr / self.lineSize) % (self.numLines / self.associativity))

    def cacheAccess(self, addr, debug=False, partition_id=0):
        self.clock +=1 
        tag = self.getTag(addr)
        setIndex = self.getSet(addr)
        for way_id in self.parts[partition_id]:
            if tag == self.tagStore[setIndex, way_id]:
                self.touchLRU(setIndex, way_id)
                return True
        return False

    def cacheRepl(self, addr, debug=False, partition_id=0):
        assert(self.cacheAccess(addr, partition_id=partition_id) is False)       
        setIndex = self.getSet(addr)
        for way_id in self.parts[partition_id]:
            if self.tagStore[setIndex][way_id] == INVALID_TAG:
                self.insert(addr, setIndex, way_id)
                return 

        victim_way = min(
            self.parts[partition_id],
            key=lambda way_id: self.LRUStore[setIndex, way_id]
        )

        self.insert(addr, setIndex, victim_way)
        return
    
    def insert(self, addr, setIndex, way_id):
        self.touchLRU(setIndex, way_id)
        self.tagStore[setIndex][way_id] = self.getTag(addr)

    def touchLRU(self, setIndex, way_id):
        self.LRUStore[setIndex, way_id] = self.clock
        return


parts = {
    0: [0, 1],
    1: [2, 3]
}

cache = wayPartLRUCache(
    numLines=64,
    associativity=4,
    lineSize=64,
    parts=parts
)

addr = 0x1000

if cache.cacheAccess(addr, partition_id=0, debug=True) is False:
    cache.cacheRepl(addr, partition_id=0, debug=True)

addr = 0x2000

if cache.cacheAccess(addr, partition_id=1, debug=True) is False:
    cache.cacheRepl(addr, partition_id=1, debug=True)