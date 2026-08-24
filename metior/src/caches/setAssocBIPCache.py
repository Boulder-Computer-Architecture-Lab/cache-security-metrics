import numpy as np
import sys
import random

cache_debug = False
INVALID_TAG = -1
INT_MAX = sys.maxsize

class setAssocBIPCache:
    def __init__(self, numLines, associativity, lineSize):
        self.numLines = numLines
        self.associativity = associativity
        self.lineSize = lineSize 

        self.clock = 0
        self.btp = 1/32 
        self.tagStore = np.ones((int(numLines/associativity), associativity), dtype=np.int32) * INVALID_TAG
        self.BIPStore = np.zeros((int(numLines/associativity), associativity), dtype=np.int32) 
        random.seed(0xc0ffee)

    def clearCache(self, debug=False):
        self.tagStore = np.ones((int(self.numLines/self.associativity), self.associativity), dtype=np.int32) * INVALID_TAG
        self.BIPStore = np.zeros((int(self.numLines/self.associativity), self.associativity), dtype=np.int32) 

    def getTag(self, addr):
        return int(addr / (self.lineSize * (self.numLines / self.associativity)))

    def getSet(self, addr):
        return int((addr / self.lineSize) % (self.numLines / self.associativity))

    def cacheAccess(self, addr, debug=False):
        self.clock +=1 
        
        tag = self.getTag(addr)
        setIndex = self.getSet(addr)
        for way_id in range(self.associativity):
            if tag == self.tagStore[setIndex, way_id]:
                self.touchBIP(setIndex, way_id)
                return True
        return False

    def cacheRepl(self, addr, debug):
        assert(self.cacheAccess(addr) is False)       
        setIndex = self.getSet(addr)
        lru = INT_MAX
        victim_id = random.randint(0, self.associativity-1)
        for way_id in range(self.associativity):
            if self.tagStore[setIndex][way_id] == INVALID_TAG:
                victim_id = way_id
                self.insert(addr, setIndex, victim_id)
                return 
            if self.BIPStore[setIndex, way_id] < lru:
                lru = self.BIPStore[setIndex, way_id]
                victim_id = way_id
        self.insert(addr, setIndex, victim_id)
        return

    def insert(self, addr, setIndex, way_id):
        self.touchBIP(setIndex, way_id)
        self.tagStore[setIndex][way_id] = self.getTag(addr)

    def insertBIP(self, setIndex, way_id):
        if random.randint(0, 100) <= self.btp:
            # Insert as MRU if lower than btp
            self.BIPStore[setIndex, way_id] = self.clock
        else:
            # Make timestamp as old as possible, become LRU
            self.BIPStore[setIndex, way_id] = 1            
        return

    def touchBIP(self, setIndex, way_id):
        self.BIPStore[setIndex, way_id] = self.clock
