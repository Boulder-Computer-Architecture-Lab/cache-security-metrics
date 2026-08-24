import numpy as np
import sys
import random

cache_debug = False
INVALID_TAG = -1
INT_MAX = sys.maxsize

class SatCounter:
    def __init__(self, bits, initialVal=0):
        self.bits = bits
        self.max_value = (1 << bits) - 1 
        self.min_value = 0
        self.value = max(min(initialVal, self.max_value), self.min_value)
        self.initialVal = initialVal

    def increment(self):
        if self.value < self.max_value:
            self.value += 1

    def decrement(self):
        if self.value > self.min_value:
            self.value -= 1

    def reset(self):
        self.value = self.initialVal

    def saturate(self):
        diff = self.max_value - self.value
        self.value = self.max_value
        return diff
        
    def __repr__(self):
        return f"{self.value}/{self.max_value}"
    

class setAssocBRRIPCache:
    class RRPVStore:
        def __init__(self, numBits):
            self.rrpv = SatCounter(numBits)

    def __init__(self, numLines, associativity, lineSize):
        self.numLines = numLines
        self.associativity = associativity
        self.lineSize = lineSize 

        self.clock = 0
        self.btp = 1/32 
        self.numRRPVBits = 2
        self.hitPriority = False

        self.tagStore = np.ones((int(numLines/associativity), associativity), dtype=np.int32) * INVALID_TAG
        self.BRRIPStore = np.empty((int(numLines/associativity), associativity), dtype=object) 
        for i in range(int(numLines/associativity)):
            for j in range(associativity):
                self.BRRIPStore[i, j] = self.RRPVStore(self.numRRPVBits)

        random.seed(0xc0ffee)

    def clearCache(self, debug=False):
        self.tagStore = np.ones((int(self.numLines/self.associativity), self.associativity), dtype=np.int32) * INVALID_TAG
        self.BRRIPStore = np.empty((int(self.numLines/self.associativity), self.associativity), dtype=object) 
        for i in range(int(self.numLines/self.associativity)):
            for j in range(self.associativity):
                self.BRRIPStore[i, j] = self.RRPVStore(self.numRRPVBits)


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
                self.touchBRRIP(setIndex, way_id)
                return True
        return False

    def cacheRepl(self, addr, debug):
        assert(self.cacheAccess(addr) is False)
        setIndex = self.getSet(addr)
        victim_rrpv = 0
        victim_id = random.randint(0, self.associativity-1)
        for way_id in range(self.associativity):
            if self.tagStore[setIndex][way_id] == INVALID_TAG:
                victim_id = way_id
                self.insert(addr, setIndex, victim_id)
                return
            if self.BRRIPStore[setIndex, way_id].rrpv.value > victim_rrpv:
                victim_id = way_id
                victim_rrpv = self.BRRIPStore[setIndex, way_id].rrpv.value
        diff = self.BRRIPStore[setIndex, victim_id].rrpv.saturate()
        if (diff > 0):
            for way_id in range(self.associativity):
                self.BRRIPStore[setIndex, way_id].rrpv.value += diff
        self.insert(addr, setIndex, victim_id)
        return

    def insert(self, addr, setIndex, way_id):
        self.insertBRRIP(setIndex, way_id)
        self.tagStore[setIndex][way_id] = self.getTag(addr)

    def insertBRRIP(self, setIndex, way_id):
        self.BRRIPStore[setIndex, way_id].rrpv.saturate()
        if random.randint(0, 100) <= self.btp:
            self.BRRIPStore[setIndex, way_id].rrpv.decrement()            

    def touchBRRIP(self, setIndex, way_id):
        if (self.hitPriority):
            self.BRRIPStore[setIndex, way_id].rrpv.reset()
        else:
            self.BRRIPStore[setIndex, way_id].rrpv.decrement()            
