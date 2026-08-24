import numpy as np
import sys
import random

cache_debug = False
INVALID_TAG = -1
INT_MAX = sys.maxsize

class setAssocLRUCache:
    def __init__(self, numLines, associativity, lineSize):
        self.numLines = numLines
        self.associativity = associativity
        self.lineSize = lineSize 
        
        self.tagStore = np.ones((int(numLines/associativity), associativity), dtype=np.int32) * INVALID_TAG
        self.LRUStore = np.zeros((int(numLines/associativity), associativity), dtype=np.int32) 
        self.clock = 0

    def clearCache(self, debug=False):
        self.tagStore = np.ones((int(self.numLines/self.associativity), self.associativity), dtype=np.int32) * INVALID_TAG
        self.LRUStore = np.zeros((int(self.numLines/self.associativity), self.associativity), dtype=np.int32) 
        self.clock = 0

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
                self.touchLRU(setIndex, way_id)
                return True
        return False

    def cacheRepl(self, addr, debug):
        assert(self.cacheAccess(addr) is False)       
        setIndex = self.getSet(addr)
        for way_id in range(self.associativity):
            if self.tagStore[setIndex][way_id] == INVALID_TAG:
                self.insert(addr, setIndex, way_id)
                return 
        victim_way = np.argmin(self.LRUStore[setIndex])
        self.insert(addr, setIndex, victim_way)
        return
    
    def insert(self, addr, setIndex, way_id):
        self.touchLRU(setIndex, way_id)
        self.tagStore[setIndex][way_id] = self.getTag(addr)

    def touchLRU(self, setIndex, way_id):
        self.LRUStore[setIndex, way_id] = self.clock
        return
