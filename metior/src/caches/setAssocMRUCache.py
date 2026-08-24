import random
import numpy as np

cache_debug = False
INVALID_TAG = -1

class setAssocMRUCache:
    def __init__(self, numLines, associativity, lineSize):
        self.numLines = numLines
        self.associativity = associativity
        self.lineSize = lineSize     

        self.tagStore = np.ones((int(numLines/associativity), associativity), dtype=np.int32) * INVALID_TAG
        self.MRUStore = np.zeros((int(numLines/associativity), associativity), dtype=np.int32) 
        self.clock = 0

    def clearCache(self, debug=False):
        self.tagStore = np.ones((int(self.numLines/self.associativity), self.associativity), dtype=np.int32) * INVALID_TAG
        self.MRUStore = np.zeros((int(self.numLines/self.associativity), self.associativity), dtype=np.int32) 
        self.clock = 0

    def getTag(self, addr):
        return int(addr / (self.lineSize * (self.numLines / self.associativity)))

    def getSet(self, addr):
        return int((addr / self.lineSize) % (self.numLines / self.associativity))

    def cacheAccess(self, addr, debug=False):
        self.clock += 1
        tag = self.getTag(addr)
        setIndex = self.getSet(addr)
        for way_id in range(self.associativity):
            if tag == self.tagStore[setIndex, way_id]:
                self.touchMRU(setIndex, way_id)
                return True
        return False

    def cacheRepl(self, addr, debug):
        assert(self.cacheAccess(addr) is False)        
        setIndex = self.getSet(addr)
        for way_id in range(self.associativity):
            if self.tagStore[setIndex][way_id] == INVALID_TAG:
                self.insert(addr, setIndex, way_id)
                break
        # Find the most recently used way in the set
        victim_way = np.argmax(self.MRUStore[setIndex])               
        self.insert(addr, setIndex, victim_way)
        return
        
    def insert(self, addr, idx, way):
        self.touchMRU(idx, way)
        self.tagStore[idx, way] = self.getTag(addr)
        
    def touchMRU(self, idx, way):
        self.MRUStore[idx, way] = self.clock
        return
